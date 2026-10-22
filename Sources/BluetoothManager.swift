import Foundation
import Darwin

// Isolate Classic Bluetooth discovery in the system helper. An unresponsive
// IOBluetooth service can no longer leave a framework call inside this process.
struct SystemBluetoothSnapshot {
    static func parse(_ data: Data) -> HeadphoneState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        var fallback: HeadphoneState?
        for controller in controllers {
            for key in ["device_connected", "device_not_connected"] {
                for entry in controller[key] as? [[String: [String: Any]]] ?? [] {
                    for (name, info) in entry where QCYProtocol.targetName(name) {
                        var state = HeadphoneState()
                        state.found = true; state.name = name
                        state.connected = key == "device_connected"
                        state.firmware = info["device_firmwareVersion"] as? String
                        if state.connected {
                            state.battery = BatteryParser.percentage(info["device_batteryLevelMain"])
                                ?? BatteryParser.percentage(info["device_batteryLevel"])
                        }
                        state.note = state.connected ? "Dispositivo conectado ao Mac." : "Pareado; desconectado neste momento."
                        state.updated = Date()
                        if state.connected { return state }
                        fallback = state
                    }
                }
            }
        }
        if let fallback { return fallback }
        var state = HeadphoneState()
        state.note = controllers.contains { $0["controller_properties"] != nil }
            ? "QCY T13 ANC não encontrado no sistema." : "Informações Bluetooth não disponibilizadas pelo sistema."
        state.updated = Date()
        return state
    }
}

@MainActor final class BluetoothManager: ObservableObject {
    @Published var state = HeadphoneState()
    private var refreshing = false
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> HeadphoneState in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "8"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                var failure = HeadphoneState()
                failure.note = "Não foi possível consultar o Bluetooth do sistema."
                failure.updated = Date()
                do {
                    try process.run()
                    let terminate = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    let force = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: terminate)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: force)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    terminate.cancel(); force.cancel()
                    guard process.terminationStatus == 0, data.count <= 1_048_576,
                          let snapshot = SystemBluetoothSnapshot.parse(data) else { return failure }
                    return snapshot
                } catch { return failure }
            }.value
            state = result
            refreshing = false
        }
    }
}
