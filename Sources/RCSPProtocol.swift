import Foundation

// Independent wire-format implementation. Evidence and APK digest: PROTOCOL.md.
// Only the legacy Jieli branch for product 0x4772 is supported here.
struct RCSPPacket: Equatable, Sendable {
    let command: Bool
    let wantsResponse: Bool
    let opcode: UInt8
    let sequence: UInt8
    let status: UInt8?
    let payload: [UInt8]
    var data: Data {
        let body = (command ? [sequence] : [status ?? 0, sequence]) + payload
        return Data([0xfe, 0xdc, 0xba, (command ? 0x80 : 0) | (wantsResponse ? 0x40 : 0), opcode,
                     UInt8(body.count >> 8), UInt8(body.count & 255)] + body + [0xef])
    }
}
struct RCSPDecoder: Sendable {
    private var buffer: [UInt8] = []
    mutating func consume(_ data: Data) -> [RCSPPacket] {
        guard data.count <= 4096 else { buffer = []; return [] }
        buffer.append(contentsOf: data)
        if buffer.count > 8192 { buffer = []; return [] }
        var packets: [RCSPPacket] = []
        while buffer.count >= 3 {
            guard buffer[0...2].elementsEqual([0xfe, 0xdc, 0xba]) else { buffer.removeFirst(); continue }
            guard buffer.count >= 7 else { break }
            let count = Int(buffer[5]) << 8 | Int(buffer[6])
            let command = buffer[3] & 0x80 != 0
            guard buffer[3] & 0x3f == 0, count >= (command ? 1 : 2), count <= 2048 else { buffer.removeFirst(); continue }
            guard buffer.count >= count + 8 else { break }
            guard buffer[count + 7] == 0xef else { buffer.removeFirst(); continue }
            let body = Array(buffer[7..<(count + 7)])
            packets.append(RCSPPacket(command: command, wantsResponse: buffer[3] & 0x40 != 0, opcode: buffer[4],
                sequence: body[command ? 0 : 1], status: command ? nil : body[0], payload: Array(body.dropFirst(command ? 1 : 2))))
            buffer.removeFirst(count + 8)
        }
        return packets
    }
}
struct RCSPTouch: Identifiable, Equatable, Sendable {
    let side: UInt8
    let gesture: UInt8
    var function: UInt8
    var id: Int { Int(side) << 8 | Int(gesture) }
    var title: String { "\(side == 1 ? "Esquerdo" : "Direito") · \([1: "Um toque", 2: "Dois toques", 3: "Três toques", 4: "Quatro toques", 5: "Pressionar" ][Int(gesture)] ?? "Gesto \(gesture)")" }
    static let functions: [(UInt8, String)] = [(127,"Sem ação"),(1,"Reproduzir / pausar"),(2,"Faixa anterior"),(3,"Próxima faixa"),(4,"Assistente"),(5,"Aumentar volume"),(6,"Diminuir volume"),(7,"Modo jogo"),(11,"Cancelamento de ruído"),(14,"Alternar modos")]
}
struct RCSPBattery: Equatable, Sendable {
    struct Cell: Equatable, Sendable {
        let percentage: Int
        let charging: Bool
    }
    let left: Cell?
    let right: Cell?
    let caseBattery: Cell?
    var available: Bool { left != nil || right != nil || caseBattery != nil }
    static func parse(_ bytes: [UInt8]) -> RCSPBattery? {
        guard bytes.count == 3 else { return nil }
        func cell(_ byte: UInt8) -> Cell? {
            let level = Int(byte & 0x7f)
            guard level <= 100 else { return nil }
            return Cell(percentage: level, charging: byte & 0x80 != 0)
        }
        // Zero from the case is ambiguous when it is not reporting charging:
        // the buds may be connected while the case is out of radio range.
        let caseCell = bytes[2] == 0 ? nil : cell(bytes[2])
        let result = RCSPBattery(left: cell(bytes[0]), right: cell(bytes[1]), caseBattery: caseCell)
        return result.available ? result : nil
    }
}
enum RCSPProtocol {
    static func legacyProduct(_ id: UInt16?) -> Bool { id == 0x4772 }
    static func ltv(_ bytes: [UInt8]) -> [(UInt8, [UInt8])]? {
        var result: [(UInt8, [UInt8])] = []; var offset = 0
        while offset < bytes.count {
            let count = Int(bytes[offset])
            guard count >= 1, offset + count + 1 <= bytes.count else { return nil }
            result.append((bytes[offset + 1], Array(bytes[(offset + 2)..<(offset + count + 1)])))
            offset += count + 1
        }
        return result
    }
    static func field(_ type: UInt8, _ bytes: [UInt8]) -> [UInt8] { [UInt8(bytes.count + 1), type] + bytes }
    // QCY's product-specific curves, distinct from the generic Jieli bank IDs.
    // Sources: outputs/PERFIL-T13-ANC.json and the Jieli EQ documentation.
    static let eqCurves: [[Int8]] = [
        [0,0,0,0,0,0,0,0,0,0],
        [-6,5,-3,-2,5,4,-4,5,4,0],
        [4,4,3,1,0,0,0,0,0,0],
        [5,4,4,2,1,0,0,0,0,0],
        [-1,-3,-3,2,4,4,3,1,-1,0],
        [6,4,-2,-1,-4,5,1,0,0,0]
    ]
    static func eqGains(_ preset: UInt8) -> [UInt8]? {
        guard Int(preset) < eqCurves.count else { return nil }
        return eqCurves[Int(preset)].map { UInt8(bitPattern: $0) }
    }
    static func eqPreset(_ raw: [UInt8]?) -> UInt8? {
        guard let raw, raw.count == 11 else { return nil }
        let gains = raw.dropFirst().map { Int8(bitPattern: $0) }
        return eqCurves.firstIndex(of: gains).map(UInt8.init)
    }
    static let advQuery: [UInt8] = [0, 0, 0x08, 0x25] // battery bit 0, noise bit 11, work mode bit 5, keys bit 2
    static let batteryQuery: [UInt8] = [0, 0, 0, 1]
    static let eqQuery: [UInt8] = [0xff, 0, 0, 0, 0x10] // public function, EQ attribute bit 4
    static func validNoiseRecord(_ raw: [UInt8]) -> Bool {
        // Legacy firmware also returns [mode, 0] with no gain data.
        // Confirmed by the user's real response (02 00) and NoiseMode.parseData.
        guard raw.count >= 2 else { return false }
        guard (raw[1] == 0 && (raw.count == 2 || raw.count == 8)) || (raw[1] == 6 && raw.count == 8) else { return false }
        if raw[1] == 6 {
            let min = Int(raw[2]) << 8 | Int(raw[3]); let max = Int(raw[4]) << 8 | Int(raw[5])
            let current = Int(raw[6]) << 8 | Int(raw[7])
            guard min <= current, current <= max else { return false }
        }
        return true
    }
    static func noise(_ raw: [UInt8]) -> NoiseMode? {
        guard validNoiseRecord(raw) else { return nil }
        // Official QCY control panel for product 18290, firmware 2.4.0.
        switch raw[0] { case 2: return .normal; case 65: return .anc; case 3: return .transparency; default: return nil }
    }
    static func noiseBytes(_ mode: NoiseMode, preserving raw: [UInt8]) -> [UInt8]? {
        guard validNoiseRecord(raw) else { return nil }
        // QCY 4.0.7 ItemViewANCPercent.onItemClick passes changeMode=true.
        // QCYConnectManager then creates a NEW NoiseMode, setting only mode:
        // length and gains remain zero. Reusing the gain record is for changing
        // intensity, a separate operation that this UI does not expose.
        let code: UInt8 = mode == .normal ? 2 : mode == .anc ? 65 : 3
        return [code, 0, 0, 0, 0, 0, 0, 0]
    }
}

// A single request is outstanding. Transport submission and protocol acknowledgement
// are separate: GATT success never confirms a device setting.
struct RCSPClient: Sendable {
    enum Purpose: Equatable, Sendable { case info, adv, battery, eq, writeAdv, writeEQ }
    struct Request: Sendable {
        let packet: RCSPPacket
        let purpose: Purpose
        let settleDelay: TimeInterval
    }
    enum Expected: Equatable, Sendable { case noise(NoiseMode), game(Bool), eq(UInt8), customEQ([UInt8]), touch(Int, UInt8) }
    private(set) var current: Request?
    private var requests: [(UInt8, [UInt8], Purpose)] = []
    private var sequence: UInt8 = 0
    private var readbackAttempts = 0
    private var decoder = RCSPDecoder()
    private(set) var firmware: String?
    private(set) var infoConfirmed = false
    private(set) var upgradeRequired = false
    private(set) var noiseRaw: [UInt8]?
    private(set) var game: Bool?
    private(set) var eqRaw: [UInt8]?
    private(set) var touches: [RCSPTouch] = []
    private(set) var battery: RCSPBattery?
    private(set) var expected: Expected?
    private(set) var failed = false
    private(set) var error: String?
    private(set) var confirmation: String?
    private(set) var logs: [String] = []
    var noise: NoiseMode? { noiseRaw.flatMap(RCSPProtocol.noise) }
    var preset: UInt8? { RCSPProtocol.eqPreset(eqRaw) }
    var ready: Bool { infoConfirmed && firmware != nil && !upgradeRequired && !failed }
    var canNoise: Bool { ready && noiseRaw.map(RCSPProtocol.validNoiseRecord) == true }
    var canGame: Bool { ready && game != nil }
    var canEQ: Bool { ready && eqRaw?.count == 11 && ((eqRaw?.first ?? 254) <= 6 || eqRaw?.first == 255) }
    var canTouch: Bool { ready && !touches.isEmpty }
    var busy: Bool { expected != nil }
    mutating func start() {
        self = RCSPClient()
        // Same information request as the inspected app. Response values containing
        // addresses/serials are discarded and never copied into our diagnostic.
        requests = [(3, [255,255,255,255,0], .info)]
    }
    mutating func next() -> Request? {
        guard !failed, current == nil, !requests.isEmpty else { return nil }
        let (opcode, payload, purpose) = requests.removeFirst()
        let packet = RCSPPacket(command: true, wantsResponse: true, opcode: opcode, sequence: sequence, status: nil, payload: payload)
        sequence &+= 1
        let request = Request(packet: packet, purpose: purpose, settleDelay: expected != nil && (purpose == .adv || purpose == .eq) ? 0.5 : 0)
        current = request
        logs.append("RCSP TX opcode \(opcode), sequência \(packet.sequence), \(payload.count) bytes.")
        return request
    }
    mutating func timeout() {
        guard let current else { return }
        logs.append("RCSP sem resposta ao opcode \(current.packet.opcode), sequência \(current.packet.sequence).")
        if current.purpose == .battery { battery = nil }
        if current.purpose == .info || busy { fail("O fone não respondeu ao protocolo RCSP. Reconecte os controles e copie o diagnóstico.") }
        else { self.current = nil }
    }
    mutating func fail(_ message: String) {
        error = message; failed = true; expected = nil; current = nil; requests = []
    }
    mutating func refresh() {
        // A confirmed identity may be resynchronized after an operation error.
        // This performs only reads and never replays the failed configuration.
        guard infoConfirmed, firmware != nil, !upgradeRequired, current == nil, !busy else { return }
        failed = false; error = nil; confirmation = nil; readbackAttempts = 0
        noiseRaw = nil; game = nil; eqRaw = nil; touches = []; battery = nil; decoder = RCSPDecoder()
        requests = [(0xc1, RCSPProtocol.advQuery, .adv), (7, RCSPProtocol.eqQuery, .eq)]
    }
    mutating func refreshBattery() {
        guard ready, current == nil, requests.isEmpty, !busy else { return }
        requests = [(0xc1, RCSPProtocol.batteryQuery, .battery)]
    }
    mutating func receive(_ bytes: Data) {
        for packet in decoder.consume(bytes) {
            // SDK handleCommand(9) -> parseAttrMessage: a state event, not a
            // request to change settings. Never consume the outstanding reply.
            if packet.command {
                receiveStateEvent(packet)
                continue
            }
            guard let request = current, packet.opcode == request.packet.opcode, packet.sequence == request.packet.sequence else {
                logs.append("RCSP resposta sem solicitação correspondente; ignorada."); continue
            }
            current = nil
            logs.append("RCSP RX opcode \(packet.opcode), sequência \(packet.sequence), status \(packet.status ?? 255), \(packet.payload.count) bytes.")
            guard packet.status == 0 else {
                if busy || request.purpose == .info { fail("O fone recusou a solicitação RCSP (status \(packet.status ?? 255)).") }
                continue
            }
            switch request.purpose {
            case .info:
                guard let fields = RCSPProtocol.ltv(packet.payload), !fields.isEmpty else { fail("Resposta de identificação RCSP inválida."); continue }
                for (type, value) in fields {
                    logs.append("Informação RCSP tipo \(type): \(value.count) bytes (conteúdo privado omitido).")
                    if type == 5, value.count == 2 {
                        let code = Int(value[0]) << 8 | Int(value[1])
                        firmware = [12,8,4,0].map { String((code >> $0) & 15) }.joined(separator: ".")
                    }
                    if type == 9, let flag = value.first { upgradeRequired = flag != 0 }
                }
                infoConfirmed = firmware != nil
                guard infoConfirmed, !upgradeRequired else { fail("A identificação RCSP não confirmou firmware utilizável. Nenhuma configuração foi enviada."); continue }
                requests = [(0xc1, RCSPProtocol.advQuery, .adv), (7, RCSPProtocol.eqQuery, .eq)]
            case .adv:
                guard let fields = RCSPProtocol.ltv(packet.payload) else { if busy { fail("Resposta de configuração RCSP inválida.") }; continue }
                for (type, value) in fields {
                    logs.append("Atributo ADV \(type): \(value.count) bytes.")
                    if (type == 11 && value.count <= 8) || (type == 5 && value.count == 1) {
                        logs.append("Estado ADV \(type): " + value.map { String(format: "%02X", $0) }.joined(separator: " "))
                    }
                    if type == 11 { noiseRaw = RCSPProtocol.validNoiseRecord(value) ? value : nil }
                    if type == 0 {
                        battery = RCSPBattery.parse(value)
                        logs.append("Bateria RCSP bruta: " + value.map { String(format: "%02X", $0) }.joined(separator: " "))
                    }
                    if type == 5, value.count == 1, [1,2].contains(value[0]) { game = value[0] == 2 }
                    if type == 2, !value.isEmpty, value.count % 3 == 0, value.count <= 60 {
                        var parsed: [RCSPTouch] = []
                        for i in stride(from: 0, to: value.count, by: 3) where [1,2].contains(value[i]) && (1...5).contains(value[i+1]) {
                            let t = RCSPTouch(side: value[i], gesture: value[i+1], function: value[i+2])
                            if !parsed.contains(where: { $0.id == t.id }) { parsed.append(t) }
                        }
                        touches = parsed.sorted { $0.id < $1.id }
                    }
                }
                confirmReadback(fields: Set(fields.map { $0.0 }), eqRead: false)
            case .battery:
                battery = nil
                guard let fields = RCSPProtocol.ltv(packet.payload) else { continue }
                battery = fields.first(where: { $0.0 == 0 }).flatMap { RCSPBattery.parse($0.1) }
                if let raw = fields.first(where: { $0.0 == 0 })?.1 {
                    logs.append("Bateria RCSP bruta: " + raw.map { String(format: "%02X", $0) }.joined(separator: " "))
                }
                logs.append("Bateria RCSP atualizada: " + (battery == nil ? "não exposta" : "campos esquerdo, direito e estojo recebidos"))
            case .eq:
                guard packet.payload.first == 0xff, let fields = RCSPProtocol.ltv(Array(packet.payload.dropFirst())) else {
                    if busy { fail("Resposta de equalizador RCSP inválida.") }; continue
                }
                var found = false
                for (type, value) in fields where type == 4 && value.count == 11 {
                    eqRaw = value; found = true; logs.append("EQ RCSP: modo \(value[0]), 10 ganhos recebidos.")
                    logs.append("EQ ganhos RX (dB/Int8): " + value.dropFirst().map { String(Int8(bitPattern: $0)) }.joined(separator: ", "))
                    logs.append("EQ atributo RX: " + value.map { String(format: "%02X", $0) }.joined(separator: " "))
                }
                if found { confirmReadback(fields: [], eqRead: true) }
                else if expected != nil { fail("O fone não confirmou o equalizador solicitado.") }
            case .writeAdv:
                logs.append("Resultado SetADV RX: " + packet.payload.map { String(format: "%02X", $0) }.joined(separator: " "))
                // SetADVInfo has an additional result byte in its response.
                guard packet.payload == [0] else { fail("O fone não aceitou a configuração ADV."); continue }
                requests.insert((0xc1, RCSPProtocol.advQuery, .adv), at: 0)
            case .writeEQ:
                logs.append("Resultado SetSysInfo RX: " + (packet.payload.isEmpty ? "vazio" : packet.payload.map { String(format: "%02X", $0) }.joined(separator: " ")))
                requests.insert((7, RCSPProtocol.eqQuery, .eq), at: 0)
            }
        }
    }
    private mutating func receiveStateEvent(_ packet: RCSPPacket) {
        guard ready, packet.opcode == 9, packet.payload.first == 0xff,
              let fields = RCSPProtocol.ltv(Array(packet.payload.dropFirst())) else {
            logs.append("RCSP evento ignorado: opcode \(packet.opcode), sequência \(packet.sequence), \(packet.payload.count) bytes, resposta solicitada=\(packet.wantsResponse).")
            return
        }
        for (type, value) in fields {
            logs.append("RCSP evento SysInfo: atributo \(type), \(value.count) bytes.")
            guard type == 4, value.count == 11, (value[0] <= 6 || value[0] == 255) else { continue }
            logs.append("EQ evento RX: " + value.map { String(format: "%02X", $0) }.joined(separator: " "))
            // During a change preserve the queried state and explicit readback
            // requirement. The event is recorded for comparison, never success.
            if !busy && current == nil {
                eqRaw = value
                confirmation = nil
            }
        }
    }
    private mutating func confirmReadback(fields: Set<UInt8>, eqRead: Bool) {
        guard let expected else { return }
        let matches: Bool
        switch expected {
        case .noise(let mode): guard fields.contains(11) else { fail("O fone não retornou o estado de ANC após a alteração."); return }; matches = noise == mode
        case .game(let enabled): guard fields.contains(5) else { fail("O fone não retornou o modo jogo após a alteração."); return }; matches = game == enabled
        case .eq(let mode): guard eqRead else { return }; matches = preset == mode && (eqRaw?.first == 6 || eqRaw?.first == 255)
        case .customEQ(let gains): guard eqRead else { return }; matches = eqRaw.map { Array($0.dropFirst()) == gains && [6,255].contains($0[0]) } ?? false
        case .touch(let id, let function): guard fields.contains(2) else { fail("O fone não retornou os toques após a alteração."); return }; matches = touches.contains { $0.id == id && $0.function == function }
        }
        guard matches else {
            readbackAttempts += 1
            logs.append("RCSP leitura divergente \(readbackAttempts)/3: solicitado \(describe(expected)); retornado ANC=\(noiseRaw?.first.map { String(format: "%02X", $0) } ?? "ausente"), jogo=\(game.map { $0 ? "ligado" : "desligado" } ?? "ausente"), EQ=\(preset.map(String.init) ?? "ausente").")
            if readbackAttempts < 3 {
                if eqRead { requests.insert((7, RCSPProtocol.eqQuery, .eq), at: 0) }
                else { requests.insert((0xc1, RCSPProtocol.advQuery, .adv), at: 0) }
            } else {
                // A valid, different state is not a broken BLE session. Keep the
                // returned state, report non-confirmation and permit another action.
                self.expected = nil; confirmation = nil
                error = "A alteração não foi confirmada. Exibindo o estado retornado pelos fones. Você pode tentar novamente ou atualizar as funções."
            }
            return
        }
        let control: String
        switch expected {
        case .noise: control = "Cancelamento de ruído"
        case .game: control = "Modo jogo"
        case .eq, .customEQ: control = "Equalizador"
        case .touch: control = "Controle de toques"
        }
        self.expected = nil; confirmation = "\(control): alteração confirmada por leitura dos fones."
        logs.append("RCSP: leitura após escrita confirmada.")
    }
    private func describe(_ value: Expected) -> String {
        switch value {
        case .noise(let mode): return "modo \(mode.title)"
        case .game(let enabled): return "jogo \(enabled ? "ligado" : "desligado")"
        case .eq(let mode): return "EQ \(mode)"
        case .customEQ: return "EQ personalizado"
        case .touch(let id, let function): return "toque \(id), função \(function)"
        }
    }
    mutating func setNoise(_ mode: NoiseMode) {
        guard canNoise, !busy, current == nil, requests.isEmpty, let raw = noiseRaw,
              let changed = RCSPProtocol.noiseBytes(mode, preserving: raw), noise != mode else { return }
        begin(.noise(mode), opcode: 0xc0, payload: RCSPProtocol.field(11, changed), purpose: .writeAdv)
    }
    mutating func setGame(_ enabled: Bool) {
        guard canGame, !busy, current == nil, requests.isEmpty, game != enabled else { return }
        begin(.game(enabled), opcode: 0xc0, payload: RCSPProtocol.field(5, [enabled ? 2 : 1]), purpose: .writeAdv)
    }
    mutating func setPreset(_ mode: UInt8) {
        guard canEQ, !busy, current == nil, requests.isEmpty, mode != preset, let gains = RCSPProtocol.eqGains(mode) else { return }
        // QCY 4.0.7 JLDeviceImpl.setEQ uses FF for supplied custom gains.
        // Other bank IDs replace the gains with 7F in the official app.
        begin(.eq(mode), opcode: 8, payload: [0xff] + RCSPProtocol.field(4, [0xff] + gains), purpose: .writeEQ)
    }
    mutating func setGains(_ gains: [Int]) {
        guard canEQ, !busy, current == nil, requests.isEmpty,
              gains.count == 10, gains.allSatisfy({ (-6...6).contains($0) }) else { return }
        let bytes = gains.map { UInt8(bitPattern: Int8($0)) }
        guard eqRaw.map({ Array($0.dropFirst()) }) != bytes else { return }
        begin(.customEQ(bytes), opcode: 8, payload: [255] + RCSPProtocol.field(4, [255] + bytes), purpose: .writeEQ)
    }
    mutating func setTouch(_ id: Int, function: UInt8) {
        guard canTouch, !busy, current == nil, requests.isEmpty,
              RCSPTouch.functions.contains(where: { $0.0 == function }),
              let touch = touches.first(where: { $0.id == id }), touch.function != function else { return }
        begin(.touch(id, function), opcode: 0xc0, payload: RCSPProtocol.field(2, [touch.side, touch.gesture, function]), purpose: .writeAdv)
    }
    private mutating func begin(_ expected: Expected, opcode: UInt8, payload: [UInt8], purpose: Purpose) {
        self.expected = expected; readbackAttempts = 0; error = nil; confirmation = nil
        requests = [(opcode, payload, purpose)]
    }
    mutating func takeLogs() -> [String] { defer { logs = [] }; return logs }
}
