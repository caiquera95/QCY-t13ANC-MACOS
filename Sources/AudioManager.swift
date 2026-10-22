import Foundation
import CoreAudio

struct AudioOutput: Identifiable, Sendable { let id: AudioDeviceID; let name: String }
private struct AudioSnapshot: Sendable {
    let outputs: [AudioOutput]
    let selected: AudioDeviceID
    let volume: Double
    let writable: Bool
    let error: String?
}

// All HAL calls and listener management are confined to this serial worker.
private final class AudioWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "br.local.QCYControl.audio", qos: .userInitiated)
    private let sink: @Sendable (AudioSnapshot) -> Void
    private var refreshQueued = false
    init(sink: @escaping @Sendable (AudioSnapshot) -> Void) { self.sink = sink }
    func publish() { sink(AudioSnapshot(outputs: outputs, selected: selected, volume: volume, writable: writable, error: error)) }

    var outputs: [AudioOutput] = []
    var selected: AudioDeviceID = 0
    var volume: Double = 0
    var writable = false
    var error: String?
    var outputName: String { outputs.first { $0.id == selected }?.name ?? "Nenhuma saída disponível" }
    private var channels: [UInt32] = []
    private var observations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ element: UInt32 = 0) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    private func read<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, into value: inout T) -> Bool {
        var a = addr; var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, UnsafeMutableRawPointer(pointer)) == noErr
        }
    }
    private func watch(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) {
        guard !observations.contains(where: { $0.0 == id && $0.1.mSelector == addr.mSelector && $0.1.mScope == addr.mScope && $0.1.mElement == addr.mElement }) else { return }
        var a = addr
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.refreshQueued else { return }
            self.refreshQueued = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                self.refreshQueued = false
                self.refresh(); self.publish()
            }
        }
        if AudioObjectAddPropertyListenerBlock(id, &a, queue, block) == noErr { observations.append((id, addr, block)) }
    }
    func start() { refresh() }
    func refresh() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var a = address(kAudioHardwarePropertyDevices); var size: UInt32 = 0
        var ids: [AudioDeviceID] = []
        if AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 {
            ids = Array(repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &a, 0, nil, &size, $0.baseAddress!) }
            if result != noErr { ids = [] }
        }
        outputs = ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput); var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            var name: CFString = "Saída de áudio" as CFString
            _ = read(id, address(kAudioObjectPropertyName), into: &name)
            return AudioOutput(id: id, name: name as String)
        }
        var current: AudioDeviceID = 0
        _ = read(system, address(kAudioHardwarePropertyDefaultOutputDevice), into: &current)
        if selected != current {
            let obsolete = observations.filter { $0.0 != system }
            for (id, addr, block) in obsolete { var a = addr; AudioObjectRemovePropertyListenerBlock(id, &a, queue, block) }
            observations.removeAll { $0.0 != system }
        }
        selected = current
        channels = []
        var values: [Float32] = []
        // Master if supported; otherwise adjust the available stereo channels together.
        for channel: UInt32 in [0, 1, 2] {
            var value: Float32 = 0
            var property = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, channel)
            var settable: DarwinBoolean = false
            if read(current, property, into: &value), value.isFinite, (0...1).contains(value), AudioObjectIsPropertySettable(current, &property, &settable) == noErr, settable.boolValue {
                channels.append(channel); values.append(value)
                if channel == 0 { break }
            }
        }
        writable = !channels.isEmpty
        volume = values.isEmpty ? 0 : Double(values.reduce(0,+) / Float(values.count))
        watch(system, address(kAudioHardwarePropertyDefaultOutputDevice))
        watch(system, address(kAudioHardwarePropertyDevices))
        for channel in channels { watch(current, address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, channel)) }
    }
    func setVolume(_ value: Double) {
        guard writable, value.isFinite else { return }
        for channel in channels {
            var v = Float32(min(1, max(0, value)))
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, channel)
            let result = AudioObjectSetPropertyData(selected, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
            if result != noErr { error = "Não foi possível ajustar o volume (\(result))."; refresh(); return }
        }
        volume = value; error = nil
    }
    func verifyCurrentValues() -> String {
        // Idempotent hardware check: write each exact current value, then read it back.
        guard writable else { return "Áudio: saída não suporta escrita de volume." }
        for channel in channels {
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, channel)
            var original: Float32 = 0
            guard read(selected, a, into: &original) else { return "Áudio: falha de leitura." }
            var same = original
            let status = AudioObjectSetPropertyData(selected, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &same)
            var actual: Float32 = 0
            guard status == noErr, read(selected, a, into: &actual), abs(actual - original) < 0.001 else { return "Áudio: falha na verificação (\(status))." }
        }
        return "Áudio: escrita e leitura confirmadas, valores de volume preservados."
    }
    func select(_ id: AudioDeviceID) {
        guard id != selected else { return }
        var value = id; var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        let result = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        error = result == noErr ? nil : "Não foi possível trocar a saída (\(result))."
        refresh()
    }
}

@MainActor final class AudioManager: ObservableObject {
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var selected: AudioDeviceID = 0
    @Published private(set) var volume: Double = 0
    @Published private(set) var writable = false
    @Published private(set) var error: String?
    var outputName: String { outputs.first { $0.id == selected }?.name ?? "Consultando saída…" }
    private var worker: AudioWorker!
    private var volumeTask: Task<Void, Never>?
    init() {
        worker = AudioWorker { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.outputs = state.outputs; self.selected = state.selected
                self.volume = state.volume; self.writable = state.writable; self.error = state.error
            }
        }
    }
    func start() { refresh() }
    func refresh() {
        let worker = worker!
        worker.queue.async { worker.refresh(); worker.publish() }
    }
    func setVolume(_ value: Double) {
        guard writable, value.isFinite else { return }
        volumeTask?.cancel()
        let target = selected
        let worker = worker!
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            worker.queue.async {
                guard worker.selected == target else { return }
                worker.setVolume(value); worker.publish()
            }
        }
    }
    func select(_ id: AudioDeviceID) {
        volumeTask?.cancel()
        let worker = worker!
        worker.queue.async { worker.select(id); worker.publish() }
    }
    func verifyCurrentValues() async -> String {
        let worker = worker!
        return await withCheckedContinuation { continuation in
            worker.queue.async { worker.refresh(); continuation.resume(returning: worker.verifyCurrentValues()) }
        }
    }
}

extension AudioManager {
    // Regression test: a delayed backend must not delay configuration entry points
    // or the main actor. The selected ID is zero, so this does not access hardware.
    func checkResponsiveness() async -> Bool {
        let worker = worker!
        let release = DispatchSemaphore(value: 0)
        let offMain: Bool = await withCheckedContinuation { continuation in
            worker.queue.async {
                continuation.resume(returning: !Thread.isMainThread)
                _ = release.wait(timeout: .now() + 3)
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        select(0)
        try? await Task.sleep(for: .milliseconds(50))
        let responsive = ProcessInfo.processInfo.systemUptime - start < 1
        release.signal()
        return responsive && offMain
    }
}
