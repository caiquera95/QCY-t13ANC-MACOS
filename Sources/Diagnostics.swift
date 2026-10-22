import Foundation
@MainActor enum Diagnostics {
    static func report(bluetooth: BluetoothManager, audio: AudioManager) -> String {
        let s = bluetooth.state
        return "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nBluetooth: \(s.found ? "localizado" : "não localizado")\nConexão: \(s.connected ? "ativa" : "inativa")\nBateria: \(s.battery.map { "\($0)%" } ?? "não exposta")\nFirmware: \(s.firmware ?? "não exposto")\nSaída: \(audio.outputName)\nVolume gravável: \(audio.writable ? "sim" : "não")\nAtualizado: \(s.updated?.formatted(date: .omitted, time: .standard) ?? "aguardando")\nANC/jogo/EQ: consulte o diagnóstico dos controles"
    }
}
