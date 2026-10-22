import AppKit
import Combine
import CoreAudio
import Foundation

// Opt-in system-audio processing for macOS 14.2+. Uses a private, device-scoped
// Core Audio tap and one aggregate clock for capture and playback. Nothing starts
// until the user enables it; the default output device is never changed.
private struct PeakingFilter {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0
    init(frequency: Double, gain: Int, sampleRate: Double) {
        guard gain != 0 else { return }
        let a = pow(10.0, Double(gain) / 40.0)
        let w = 2.0 * Double.pi * min(frequency, sampleRate * 0.42) / sampleRate
        let alpha = sin(w) / (2.0 * 1.15)
        let divisor = 1 + alpha / a
        b0 = (1 + alpha * a) / divisor
        b1 = (-2 * cos(w)) / divisor
        b2 = (1 - alpha * a) / divisor
        a1 = (-2 * cos(w)) / divisor
        a2 = (1 - alpha / a) / divisor
    }
    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }
}

private final class SoftwareEQProcessor: @unchecked Sendable {
    private static let frequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    private var left: [PeakingFilter] = []
    private var right: [PeakingFilter] = []
    private var multiplier = 1.0
    // Configure only when the aggregate IOProc is stopped.
    func configure(gains: [Int], masterDB: Int, sampleRate: Double) {
        left = zip(Self.frequencies, gains).map { PeakingFilter(frequency: $0.0, gain: $0.1, sampleRate: sampleRate) }
        right = left
        multiplier = pow(10.0, Double(masterDB) / 20.0)
    }
    func process(_ input: Float, channel: Int) -> Float {
        var value = Double(input)
        if channel == 0 {
            for index in left.indices { value = left[index].process(value) }
        } else {
            for index in right.indices { value = right[index].process(value) }
        }
        value *= multiplier
        // Soft limiter prevents values outside the Float PCM output range.
        let magnitude = abs(value)
        if magnitude > 0.8 {
            value = (value < 0 ? -1.0 : 1.0) * min(0.99, (0.8 + 0.2 * (1.0 - exp(-(magnitude - 0.8) / 0.2))))
        }
        return Float(value)
    }
}

private final class RenderStats: @unchecked Sendable {
    var frames: Int = 0
    var inputPeak: Float = 0
    var outputPeak: Float = 0
}

private final class SoftwareEQWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "br.local.QCYControl.softwareEQ", qos: .userInitiated)
    private let callbackQueue = DispatchQueue(label: "br.local.QCYControl.softwareEQ.render", qos: .userInteractive)
    private let processor = SoftwareEQProcessor()
    private let collectStats: Bool
    init(collectStats: Bool = false) { self.collectStats = collectStats }
    private let renderStats = RenderStats()
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var started = false
    private var outputID: AudioDeviceID = 0
    private var sampleRate = 0.0
    private var inputPlanar = false
    private var outputPlanar = false

    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0, into value: inout T) -> OSStatus {
        var property = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &property, qualifierSize, qualifier, &size, $0)
        }
    }
    private func failure(_ action: String, _ code: OSStatus) -> String { "\(action) (Core Audio \(code))." }

    func start(device: AudioDeviceID, gains: [Int], masterDB: Int) -> String? {
        stop()
        guard #available(macOS 14.2, *) else { return "A amplificação do Mac exige macOS 14.2 ou posterior." }
        guard gains.count == 10, gains.allSatisfy({ (-12...12).contains($0) }), (0...6).contains(masterDB) else { return "Ajustes de ganho inválidos." }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var selected: AudioDeviceID = 0
        guard read(system, kAudioHardwarePropertyDefaultOutputDevice, into: &selected) == noErr, selected == device else { return "Selecione os QCY T13 ANC como saída de áudio antes de ativar." }
        var uid: CFString = "" as CFString
        let uidStatus = read(device, kAudioDevicePropertyDeviceUID, into: &uid)
        guard uidStatus == noErr, !String(uid).isEmpty else { return failure("Não foi possível identificar a saída", uidStatus) }
        var rate: Double = 0
        guard read(device, kAudioDevicePropertyNominalSampleRate, into: &rate) == noErr, rate >= 44100 else { return "A saída não informou uma taxa de amostragem compatível." }
        var outputFormat = AudioStreamBasicDescription()
        guard read(device, kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeOutput, into: &outputFormat) == noErr,
              outputFormat.mFormatID == kAudioFormatLinearPCM,
              outputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              outputFormat.mBitsPerChannel == 32, outputFormat.mChannelsPerFrame == 2 else {
            return "Esta saída não expõe áudio estéreo PCM de 32 bits compatível com o processamento nativo."
        }
        outputPlanar = outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        var pid = getpid()
        var processID: AudioObjectID = 0
        let processStatus = withUnsafePointer(to: &pid) { pointer in
            read(system, kAudioHardwarePropertyTranslatePIDToProcessObject, qualifier: pointer,
                 qualifierSize: UInt32(MemoryLayout<pid_t>.size), into: &processID)
        }
        guard processStatus == noErr, processID != 0 else { return failure("Não foi possível excluir o próprio aplicativo da captura", processStatus) }
        let tap = CATapDescription()
        tap.processes = [processID]
        tap.isExclusive = true
        tap.isMixdown = true
        tap.isMono = false
        tap.deviceUID = uid as String
        tap.stream = 0
        tap.name = "QCY Control · Áudio do Mac"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped
        let tapStatus = AudioHardwareCreateProcessTap(tap, &tapID)
        guard tapStatus == noErr, tapID != 0 else { tapID = 0; return failure("Não foi possível iniciar a captura de áudio", tapStatus) }
        var tapFormat = AudioStreamBasicDescription()
        let formatStatus = read(tapID, kAudioTapPropertyFormat, into: &tapFormat)
        guard formatStatus == noErr, tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32, tapFormat.mChannelsPerFrame == 2,
              abs(tapFormat.mSampleRate - outputFormat.mSampleRate) < 1 else {
            stop(); return "O formato da captura não corresponde à saída dos fones."
        }
        inputPlanar = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "QCY Control · Rota temporária",
            kAudioAggregateDeviceUIDKey: "br.local.QCYControl.eq.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: uid as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid as String]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr, aggregateID != 0 else { aggregateID = 0; stop(); return failure("Não foi possível criar a rota de áudio", aggregateStatus) }
        var alive: UInt32 = 0
        for _ in 0..<30 {
            if read(aggregateID, kAudioDevicePropertyDeviceIsAlive, into: &alive) == noErr, alive != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard alive != 0 else { stop(); return "A rota de áudio não ficou pronta. O som original foi preservado." }
        processor.configure(gains: gains, masterDB: masterDB, sampleRate: rate)
        let planarInput = inputPlanar, planarOutput = outputPlanar
        renderStats.frames = 0; renderStats.inputPeak = 0; renderStats.outputPeak = 0
        let shouldCollectStats = collectStats
        let renderProcessor = processor
        let stats = renderStats
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, callbackQueue) { _, inputData, _, outputData, _ in
            SoftwareEQWorker.render(input: inputData, output: outputData, inputPlanar: planarInput,
                                    outputPlanar: planarOutput, processor: renderProcessor, stats: stats, collectStats: shouldCollectStats)
        }
        guard ioStatus == noErr, ioProc != nil else { stop(); return failure("Não foi possível iniciar o processamento", ioStatus) }
        let startStatus = AudioDeviceStart(aggregateID, ioProc)
        guard startStatus == noErr else { stop(); return failure("Não foi possível iniciar a rota de áudio", startStatus) }
        started = true; outputID = device; sampleRate = rate
        var current: AudioDeviceID = 0
        if read(system, kAudioHardwarePropertyDefaultOutputDevice, into: &current) != noErr || current != device {
            stop()
            return "A saída do Mac mudou durante a ativação; processamento interrompido."
        }
        return nil
    }
    func update(gains: [Int], masterDB: Int) -> String? {
        guard started, let ioProc, gains.count == 10, gains.allSatisfy({ (-12...12).contains($0) }), (0...6).contains(masterDB) else { return "Amplificação do Mac indisponível." }
        let stopStatus = AudioDeviceStop(aggregateID, ioProc)
        guard stopStatus == noErr else { stop(); return failure("Não foi possível pausar o processamento", stopStatus) }
        started = false
        processor.configure(gains: gains, masterDB: masterDB, sampleRate: sampleRate)
        let startStatus = AudioDeviceStart(aggregateID, ioProc)
        guard startStatus == noErr else { stop(); return failure("Não foi possível retomar o processamento", startStatus) }
        started = true
        return nil
    }
    func stop() {
        if started, let ioProc { _ = AudioDeviceStop(aggregateID, ioProc) }
        started = false
        if let ioProc { _ = AudioDeviceDestroyIOProcID(aggregateID, ioProc) }; ioProc = nil
        if aggregateID != 0 { _ = AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 {
            if #available(macOS 14.2, *) { _ = AudioHardwareDestroyProcessTap(tapID) }
            tapID = 0
        }
        outputID = 0
    }
    var activeDevice: AudioDeviceID { outputID }
    var renderedFrames: Int { renderStats.frames } // only read after AudioDeviceStop completes
    var measuredPeaks: (Float, Float) { (renderStats.inputPeak, renderStats.outputPeak) }

    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                               inputPlanar: Bool, outputPlanar: Bool, processor: SoftwareEQProcessor, stats: RenderStats, collectStats: Bool) {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let destination = UnsafeMutableAudioBufferListPointer(output)
        for buffer in destination {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let sourceCount = inputPlanar ? 2 : 1
        let destinationCount = outputPlanar ? 2 : 1
        guard source.count >= sourceCount, destination.count >= destinationCount else { return }
        let firstSource = source.count - sourceCount // Tap streams trail any headset microphone streams.
        let s0 = source[firstSource], d0 = destination[0]
        guard let input0 = s0.mData?.assumingMemoryBound(to: Float.self),
              let output0 = d0.mData?.assumingMemoryBound(to: Float.self) else { return }
        let s1 = inputPlanar ? source[firstSource + 1] : s0
        let d1 = outputPlanar ? destination[1] : d0
        guard let input1 = s1.mData?.assumingMemoryBound(to: Float.self),
              let output1 = d1.mData?.assumingMemoryBound(to: Float.self) else { return }
        let count = min(Int(s0.mDataByteSize) / (inputPlanar ? 4 : 8), Int(s1.mDataByteSize) / (inputPlanar ? 4 : 8),
                        Int(d0.mDataByteSize) / (outputPlanar ? 4 : 8), Int(d1.mDataByteSize) / (outputPlanar ? 4 : 8))
        guard count > 0 else { return }
        stats.frames += count
        for frame in 0..<count {
            let left = input0[frame * (inputPlanar ? 1 : 2)]
            let right = input1[frame * (inputPlanar ? 1 : 2) + (inputPlanar ? 0 : 1)]
            let processedLeft = processor.process(left, channel: 0)
            let processedRight = processor.process(right, channel: 1)
            output0[frame * (outputPlanar ? 1 : 2)] = processedLeft
            output1[frame * (outputPlanar ? 1 : 2) + (outputPlanar ? 0 : 1)] = processedRight
            if collectStats {
                stats.inputPeak = max(stats.inputPeak, abs(left), abs(right))
                stats.outputPeak = max(stats.outputPeak, abs(processedLeft), abs(processedRight))
            }
        }
    }
}

@MainActor final class SoftwareEQManager: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published var gains: [Int] = {
        let stored = UserDefaults.standard.array(forKey: "softwareEQ.gains") as? [Int]
        return stored?.count == 10 && stored!.allSatisfy({ (-12...12).contains($0) }) ? stored! : Array(repeating: 0, count: 10)
    }()
    @Published var masterDB: Int = min(6, max(0, UserDefaults.standard.integer(forKey: "softwareEQ.masterDB")))
    private let worker = SoftwareEQWorker()
    private var device: AudioDeviceID = 0
    private var currentOutput: AudioDeviceID = 0
    func enable(output: AudioDeviceID, name: String) {
        guard !busy, !enabled else { return }
        currentOutput = output
        guard QCYProtocol.targetName(name) else { error = "Selecione QCY-T13 ANC como saída do Mac."; return }
        busy = true; error = nil
        let gains = gains, masterDB = masterDB, worker = worker
        worker.queue.async { [weak self] in
            let result = worker.start(device: output, gains: gains, masterDB: masterDB)
            Task { @MainActor in
                guard let self else { return }
                self.busy = false; self.enabled = result == nil; self.device = result == nil ? output : 0; self.error = result
                if self.enabled && self.currentOutput != output { self.disable() }
            }
        }
    }
    func disable() {
        guard !busy else { return }
        busy = true
        let worker = worker
        worker.queue.async { [weak self] in
            worker.stop()
            Task { @MainActor in guard let self else { return }; self.enabled = false; self.busy = false; self.device = 0; self.error = nil }
        }
    }
    func apply() {
        guard gains.count == 10, gains.allSatisfy({ (-12...12).contains($0) }), (0...6).contains(masterDB) else { return }
        UserDefaults.standard.set(gains, forKey: "softwareEQ.gains")
        UserDefaults.standard.set(masterDB, forKey: "softwareEQ.masterDB")
        guard enabled, !busy else { return }
        busy = true
        let gains = gains, masterDB = masterDB, worker = worker
        worker.queue.async { [weak self] in
            let result = worker.update(gains: gains, masterDB: masterDB)
            Task { @MainActor in
                guard let self else { return }
                self.busy = false; self.enabled = result == nil; self.error = result
                if result != nil { self.device = 0 }
            }
        }
    }
    func outputChanged(to selected: AudioDeviceID) {
        currentOutput = selected
        if enabled && selected != device { disable() }
    }
    func stopForTermination() { worker.queue.sync { worker.stop() } }
}


// Pure DSP checks; no device, tap or permission is used in --self-test.
enum SoftwareEQTests {
    static func run() -> [(String, Bool)] {
        func rms(_ frequency: Double, _ gains: [Int], _ master: Int) -> Double {
            let processor = SoftwareEQProcessor()
            processor.configure(gains: gains, masterDB: master, sampleRate: 48000)
            var sum = 0.0
            for frame in 0..<48000 {
                let sample = Float(0.02 * sin(2 * Double.pi * frequency * Double(frame) / 48000))
                let output = Double(processor.process(sample, channel: 0))
                if frame >= 24000 { sum += output * output }
            }
            return sqrt(sum / 24000)
        }
        let flat = Array(repeating: 0, count: 10)
        var bass = flat; bass[1] = 9
        let lowRatio = rms(62, bass, 0) / rms(62, flat, 0)
        let midRatio = rms(1000, bass, 0) / rms(1000, flat, 0)
        let masterRatio = rms(1000, flat, 6) / rms(1000, flat, 0)
        let hot = SoftwareEQProcessor()
        hot.configure(gains: Array(repeating: 12, count: 10), masterDB: 6, sampleRate: 48000)
        let limited = (0..<5000).allSatisfy { index in
            let output = hot.process(Float(index % 2 == 0 ? 0.95 : -0.95), channel: 0)
            return output.isFinite && abs(output) < 1
        }
        return [
            ("EQ do Mac: 62 Hz +9 dB aumenta RMS real", lowRatio > 2.0),
            ("EQ do Mac: boost de grave preserva 1 kHz", midRatio > 0.85 && midRatio < 1.2),
            ("EQ do Mac: ganho geral +6 dB aumenta RMS real", masterRatio > 1.8),
            ("EQ do Mac: limitador mantém PCM finito e dentro da faixa", limited)
        ]
    }
}


// Temporary diagnostic command: +9 dB at 62 Hz and +3 dB preamp for three seconds, then full teardown.
// Never switches the Mac's default output or stores any audio.
enum SoftwareEQDiagnostics {
    static func probe() -> String {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var output: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &output) == noErr else {
            return "EQ do Mac: saída atual indisponível."
        }
        let worker = SoftwareEQWorker(collectStats: true)
        var gains = Array(repeating: 0, count: 10); gains[1] = 9
        if let error = worker.start(device: output, gains: gains, masterDB: 3) {
            return "EQ do Mac: falha na rota temporária — \(error)"
        }
        Thread.sleep(forTimeInterval: 3)
        worker.stop()
        let peaks = worker.measuredPeaks
        return "EQ do Mac: rota temporária encerrou; \(worker.renderedFrames) quadros processados; picos de entrada \(peaks.0), saída \(peaks.1)."
    }
}
