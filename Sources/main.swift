import AppKit
import Foundation
import Combine

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let bluetooth = BluetoothManager()
    let audio = AudioManager()
    let controls = QCYControlManager()
    let softwareEQ = SoftwareEQManager()
    let settings = Settings()
    var controller: MenuBarController?
    var timer: Timer?
    var batteryTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.apply()
        if let index = CommandLine.arguments.firstIndex(of: "--ble-report"), CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            controls.startScan(probe: true)
            Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    do { try self.controls.report.write(toFile: path, atomically: true, encoding: .utf8) }
                    catch { print("Falha ao salvar diagnóstico: \(error)") }
                    print(self.controls.report)
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--verify-audio") {
            Task { print(await audio.verifyCurrentValues()); NSApp.terminate(nil) }; return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            Preview.capture(bluetooth: bluetooth, audio: audio, settings: settings, controls: controls, softwareEQ: softwareEQ, path: CommandLine.arguments[index + 1])
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            audio.start(); bluetooth.refresh()
            Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    print(Diagnostics.report(bluetooth: self.bluetooth, audio: self.audio)); NSApp.terminate(nil)
                }
            }
            return
        }
        controller = MenuBarController(bluetooth: bluetooth, audio: audio, settings: settings, controls: controls, softwareEQ: softwareEQ)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.bluetooth.refresh() } }
        timer?.tolerance = 10
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controls.refreshBattery() }
        }
        batteryTimer?.tolerance = 20
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        if CommandLine.arguments.contains("--show") { controller?.toggle() }
        // Construct the status item first; hardware never blocks this launch path.
        // Observe CoreAudio's live device list even while the popover is closed.
        audio.$outputs.map { $0.contains { QCYProtocol.targetName($0.name) } }.removeDuplicates()
            .sink { [weak self] present in
                Task { @MainActor in
                    guard let self else { return }
                    self.bluetooth.refresh()
                    if present { self.controls.systemConnectionArrived() }
                }
            }.store(in: &subscriptions)
        bluetooth.$state.map(\.connected).removeDuplicates().sink { [weak self] connected in
            if connected { Task { @MainActor in self?.controls.systemConnectionArrived() } }
        }.store(in: &subscriptions)
        audio.$selected.removeDuplicates().sink { [weak self] output in
            Task { @MainActor in self?.softwareEQ.outputChanged(to: output) }
        }.store(in: &subscriptions)
        audio.start(); bluetooth.refresh(); controls.startAutomatic()
    }
    func applicationWillTerminate(_ notification: Notification) { softwareEQ.stopForTermination(); controls.disconnect() }
    @objc func woke() { audio.refresh(); bluetooth.refresh(); controls.startAutomatic() }
}
if CommandLine.arguments.contains("--responsiveness-test") {
    Task { @MainActor in
        let audio = await AudioManager().checkResponsiveness()
        let bluetooth = await QCYControlManager().checkResponsiveness()
        print("Interface livre com áudio atrasado: \(audio ? "OK" : "FALHA")")
        print("Interface livre com Bluetooth atrasado: \(bluetooth ? "OK" : "FALHA")")
        exit(audio && bluetooth ? 0 : 1)
    }
    RunLoop.main.run()
    exit(1)
}
if CommandLine.arguments.contains("--software-eq-probe") {
    print(SoftwareEQDiagnostics.probe())
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    let checks = [BatteryParser.matches("QCY-T13 ANC"), !BatteryParser.matches("QCY T13"), !BatteryParser.matches("JBL Flip 4"), BatteryParser.percentage("75%") == 75, BatteryParser.percentage("0%") == 0, BatteryParser.percentage("101%") == nil, BatteryParser.percentage(nil) == nil]
    print("Testes de identificação e bateria: \(checks.filter { $0 }.count)/\(checks.count)")
    let protocolChecks = QCYProtocol.tests() + RCSPTests.run() + SoftwareEQTests.run()
    for (name, passed) in protocolChecks { print("\(passed ? "OK" : "FALHA") · \(name)") }
    exit(checks.allSatisfy { $0 } && protocolChecks.allSatisfy { $0.1 } ? 0 : 1)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
