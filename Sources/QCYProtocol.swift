import Foundation

// Independently implemented from the public wire-format references in PROTOCOL.md.
// Deliberately excludes reset, pairing, firmware, calibration and undocumented writes.
enum NoiseMode: UInt8, CaseIterable {
    case normal = 0, anc = 1, transparency = 3
    var title: String {
        switch self { case .normal: "Normal"; case .anc: "ANC"; case .transparency: "Transparência" }
    }
}
struct QCYCommand: Equatable {
    let opcode: UInt8
    let parameters: [UInt8]
}
struct QCYFrameDecoder {
    private var buffer: [UInt8] = []
    mutating func consume(_ data: Data) -> [QCYCommand] {
        guard data.count <= 1024 else { buffer = []; return [] }
        buffer.append(contentsOf: data)
        if buffer.count > 1024 { buffer = []; return [] }
        var result: [QCYCommand] = []
        while let marker = buffer.firstIndex(of: 0xff) {
            if marker > 0 { buffer.removeFirst(marker) }
            guard buffer.count >= 2 else { break }
            let count = Int(buffer[1])
            guard count >= 2 else { buffer.removeFirst(2); continue }
            guard buffer.count >= count + 2 else { break }
            let body = Array(buffer[2..<(count + 2)])
            buffer.removeFirst(count + 2)
            var offset = 0
            var commands: [QCYCommand] = []
            var valid = true
            while offset < body.count {
                guard offset + 2 <= body.count else { valid = false; break }
                let length = Int(body[offset + 1])
                guard offset + 2 + length <= body.count else { valid = false; break }
                commands.append(QCYCommand(opcode: body[offset], parameters: Array(body[(offset + 2)..<(offset + 2 + length)])))
                offset += length + 2
            }
            if valid { result.append(contentsOf: commands) }
        }
        if !buffer.contains(0xff) { buffer = [] }
        return result
    }
}
enum QCYServiceRole { case documentedControl, inspectionOnly, unknown }
enum QCYProtocol {
    static func serviceRole(_ uuid: String) -> QCYServiceRole {
        switch uuid.uppercased() {
        case "A001", "0000A001-0000-1000-8000-00805F9B34FB": .documentedControl
        case "A002", "0000A002-0000-1000-8000-00805F9B34FB": .inspectionOnly
        default: .unknown
        }
    }
    static let targetVendorID: UInt16 = 18290
    static let presets = ["Padrão", "Pop", "Graves", "Rock", "Suave", "Clássico"]
    static func frame(_ opcode: UInt8, _ parameters: [UInt8]) -> Data {
        precondition(parameters.count <= 253)
        return Data([0xff, UInt8(parameters.count + 2), opcode, UInt8(parameters.count)] + parameters)
    }
    static func query(_ opcode: UInt8) -> Data? {
        guard [UInt8(0x09), 0x0c].contains(opcode) else { return nil }
        return frame(0xfe, [opcode])
    }
    static func noise(_ mode: NoiseMode) -> Data { frame(0x0c, [mode.rawValue]) }
    static func game(_ enabled: Bool) -> Data { frame(0x09, [enabled ? 1 : 2]) }
    static func gameValue(_ params: [UInt8]) -> Bool? {
        guard params.count == 1 else { return nil }
        switch params[0] { case 1: return true; case 2: return false; default: return nil }
    }
    static func noiseValue(_ params: [UInt8]) -> NoiseMode? {
        guard params.count == 1 else { return nil }
        return NoiseMode(rawValue: params[0])
    }
    static func presetValue(_ bytes: Data) -> UInt8? {
        // Support the single preset byte and legacy preset + ten gain bytes only.
        guard bytes.count == 1 || bytes.count == 11, let first = bytes.first, first < presets.count else { return nil }
        return first
    }
    static func firmware(_ bytes: Data) -> String? {
        let b = Array(bytes)
        guard b.count == 3 || b.count == 6 else { return nil }
        let left = b.prefix(3).map(String.init).joined(separator: ".")
        if b.count == 6, b.prefix(3) != b.suffix(3) { return nil }
        return left
    }
    static func targetName(_ name: String) -> Bool {
        let normalized = name.uppercased().filter { $0.isLetter || $0.isNumber }
        return normalized == "QCYT13ANC" || normalized == "QCYT13ANCAPP"
    }
    // CoreBluetooth includes the little-endian Company ID before manufacturer payload.
    static func vendorID(_ data: Data?) -> UInt16? {
        guard let data else { return nil }
        let b = Array(data)
        guard b.count >= 4, b[0] == 0x1c, b[1] == 0x52 else { return nil }
        return UInt16(b[2]) << 8 | UInt16(b[3])
    }
    static func target(name: String, manufacturer: Data?) -> Bool {
        if let vendor = vendorID(manufacturer) { return vendor == targetVendorID }
        return targetName(name)
    }
    static func tests() -> [(String, Bool)] {
        var decoder = QCYFrameDecoder()
        let fragment = decoder.consume(Data([0xff, 3, 0x09]))
        let finished = decoder.consume(Data([1, 2]))
        var malformed = QCYFrameDecoder()
        var bundled = QCYFrameDecoder()
        let pairs = bundled.consume(Data([0xff, 6, 9, 1, 1, 12, 1, 3]))
        return [
            ("A001 documentado", serviceRole("A001") == .documentedControl),
            ("A002 somente inspeção", serviceRole("A002") == .inspectionOnly),
            ("UUID expandido A002", serviceRole("0000a002-0000-1000-8000-00805f9b34fb") == .inspectionOnly),
            ("UUID desconhecido bloqueado", serviceRole("FEE8") == .unknown),
            ("UUID de outra base bloqueado", serviceRole("0000a001-1111-1000-8000-00805f9b34fb") == .unknown),
            ("consulta somente leitura", query(9) == Data([255,3,254,1,9])),
            ("bloqueia reset na consulta", query(3) == nil),
            ("ANC", noise(.anc) == Data([255,3,12,1,1])),
            ("modo jogo desligado usa 2", game(false) == Data([255,3,9,1,2])),
            ("notificação fragmentada", fragment.isEmpty && finished == [QCYCommand(opcode: 9, parameters: [2])]),
            ("múltiplos comandos", pairs.count == 2 && pairs.last?.parameters == [3]),
            ("pacote truncado rejeitado", malformed.consume(Data([255,3,9,4,1])).isEmpty),
            ("modo desconhecido rejeitado", noiseValue([2]) == nil),
            ("resposta jogo inválida", gameValue([0]) == nil && gameValue([1,0]) == nil),
            ("preset inválido", presetValue(Data([6])) == nil && presetValue(Data()) == nil),
            ("preset conhecido", presetValue(Data([5])) == 5),
            ("firmware exato", firmware(Data([2,4,0])) == "2.4.0"),
            ("firmware divergente rejeitado", firmware(Data([2,4,0,2,3,0])) == nil),
            ("modelo exato", targetName("QCY-T13 ANC") && !targetName("QCY T13 ANC2")),
            ("fabricante identificado", vendorID(Data([0x1c,0x52,0x47,0x72])) == 18290),
            ("outro modelo rejeitado", !target(name: "QCY-T13 ANC", manufacturer: Data([0x1c,0x52,0x47,0x76])))
        ]
    }
}
