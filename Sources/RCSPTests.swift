import Foundation

enum RCSPTests {
    static func run() -> [(String, Bool)] {
        var tests: [(String, Bool)] = []
        func check(_ title: String, _ passed: Bool) { tests.append(("RCSP · " + title, passed)) }
        let query = RCSPPacket(command: true, wantsResponse: true, opcode: 3, sequence: 0, status: nil, payload: [255,255,255,255,0])
        let golden: [UInt8] = [0xfe,0xdc,0xba,0xc0,3,0,6,0,255,255,255,255,0,0xef]
        check("consulta de identificação: vetor independente", query.data == Data(golden))
        check("produto legado exato", RCSPProtocol.legacyProduct(18290) && !RCSPProtocol.legacyProduct(18291) && !RCSPProtocol.legacyProduct(nil))
        var decoder = RCSPDecoder()
        var decoded: [RCSPPacket] = []
        for byte in golden { decoded += decoder.consume(Data([byte])) }
        check("fragmentação byte a byte", decoded == [query])
        check("vários pacotes numa notificação", decoder.consume(query.data + query.data) == [query,query])
        check("ruído anterior ao cabeçalho", decoder.consume(Data([0,0xaa,0xfe]) + query.data) == [query])
        var bad = golden; bad[13] = 0
        check("terminador incorreto rejeitado e recuperação", decoder.consume(Data(bad) + query.data) == [query])
        var oversize = golden; oversize[5] = 0xff; oversize[6] = 0xff
        check("comprimento excessivo rejeitado", decoder.consume(Data(oversize) + query.data) == [query])
        check("LTV truncado rejeitado", RCSPProtocol.ltv([8,11,1]) == nil && RCSPProtocol.ltv([0]) == nil)
        let normal: [UInt8] = [2,6,0,0,0,100,0,30]
        let anc: [UInt8] = [65,6,0,0,0,100,0,100]
        check("troca ANC cria registro de modo sem ganhos", RCSPProtocol.noiseBytes(.anc, preserving: normal) == [65,0,0,0,0,0,0,0])
        check("transparência usa código oficial 3", RCSPProtocol.noiseBytes(.transparency, preserving: normal)?.first == 3)
        check("ganho inválido bloqueado", RCSPProtocol.noise([1,6,0,50,0,100,0,20]) == nil)
        check("ANC compacto real 02 00 é Normal", RCSPProtocol.noise([2,0]) == .normal)
        check("ANC compacto normal e ligado", RCSPProtocol.noise([2,0]) == .normal && RCSPProtocol.noise([65,0]) == .anc)
        check("escrita ANC compacto segue NoiseMode.toData", RCSPProtocol.noiseBytes(.anc, preserving: [2,0]) == [65,0,0,0,0,0,0,0])
        check("ANC compacto truncado rejeitado", RCSPProtocol.noise([2]) == nil && RCSPProtocol.noise([2,6]) == nil)
        check("ANC compacto modo desconhecido rejeitado", RCSPProtocol.noise([7,0]) == nil)
        check("estrutura desconhecida bloqueada", RCSPProtocol.noise([1,4,0,0,0,0,0,0]) == nil)
        check("consulta ADV inclui bateria sem alterar os outros bits", RCSPProtocol.advQuery == [0,0,8,0x25])
        check("baterias independentes e carga", RCSPBattery.parse([0x50,0xC6,0x32]) == RCSPBattery(left: .init(percentage: 80, charging: false), right: .init(percentage: 70, charging: true), caseBattery: .init(percentage: 50, charging: false)))
        check("bateria ausente não vira porcentagem", RCSPBattery.parse([127,80,127]) == RCSPBattery(left: nil, right: .init(percentage: 80, charging: false), caseBattery: nil) && RCSPBattery.parse([127,127,127]) == nil && RCSPBattery.parse([80,80]) == nil)
        check("estojo zero sem carga é indeterminado", RCSPBattery.parse([80,70,0])?.caseBattery == nil && RCSPBattery.parse([80,70,0x80])?.caseBattery == .init(percentage: 0, charging: true))
        var client = RCSPClient()
        client.setNoise(.anc); client.setGame(true); client.setPreset(1); client.setTouch(258, function: 3)
        check("nenhuma configuração antes de consultar", client.next() == nil)
        client.start()
        let info = client.next()!
        let infoPayload = RCSPProtocol.field(5,[0x02,0x40]) + RCSPProtocol.field(9,[0])
        func response(_ request: RCSPClient.Request, _ payload: [UInt8], status: UInt8 = 0) -> Data {
            RCSPPacket(command: false, wantsResponse: false, opcode: request.packet.opcode, sequence: request.packet.sequence, status: status, payload: payload).data
        }
        let wrong = RCSPPacket(command: false, wantsResponse: false, opcode: 3, sequence: 99, status: 0, payload: infoPayload)
        client.receive(wrong.data)
        check("resposta com sequência errada ignorada", client.current != nil && !client.infoConfirmed)
        let wrongOpcode = RCSPPacket(command: false, wantsResponse: false, opcode: 0xc1, sequence: info.packet.sequence, status: 0, payload: infoPayload)
        client.receive(wrongOpcode.data)
        check("resposta com opcode errado ignorada", client.current != nil && !client.infoConfirmed)
        client.receive(response(info, infoPayload))
        check("firmware vem da resposta", client.firmware == "0.2.4.0" && client.ready && !client.canNoise)
        let adv = client.next()!
        let advPayload = RCSPProtocol.field(0,[80,70,50]) + RCSPProtocol.field(11,normal) + RCSPProtocol.field(5,[1]) + RCSPProtocol.field(2,[1,2,1])
        client.receive(response(adv,advPayload))
        let eq = client.next()!
        client.receive(response(eq, [0xff] + RCSPProtocol.field(4,[0]+Array(repeating: 0, count: 10))))
        check("recursos liberados somente por respostas", client.canNoise && client.canGame && client.canEQ && client.canTouch)
        check("baterias recebidas na mesma consulta", client.battery?.left?.percentage == 80 && client.battery?.right?.percentage == 70 && client.battery?.caseBattery?.percentage == 50)
        client.refreshBattery()
        let batteryRequest = client.next()!
        check("atualização de bateria é somente leitura", batteryRequest.packet.opcode == 0xc1 && batteryRequest.packet.payload == [0,0,0,1])
        client.receive(response(batteryRequest, RCSPProtocol.field(0,[79,69,49])))
        check("bateria atualizada sem mudar ANC", client.battery?.left?.percentage == 79 && client.noise == .normal && !client.failed)
        let ready = client
        func event(_ payload: [UInt8], opcode: UInt8 = 9) -> Data {
            RCSPPacket(command: true, wantsResponse: false, opcode: opcode, sequence: 77, status: nil, payload: payload).data
        }
        var events = ready
        let popEvent: [UInt8] = [255] + RCSPProtocol.field(4, [6] + RCSPProtocol.eqGains(1)!)
        events.receive(event(popEvent))
        check("evento EQ atualiza estado ocioso sem escrita", events.preset == 1 && events.next() == nil && events.confirmation == nil)
        events.setPreset(2); let eventWrite = events.next()!
        events.receive(event([255] + RCSPProtocol.field(4, [6] + RCSPProtocol.eqGains(2)!)))
        check("evento não consome ACK nem confirma ajuste", events.current?.packet == eventWrite.packet && events.busy && events.confirmation == nil && events.preset == 1)
        var unsafeEvents = ready
        unsafeEvents.receive(event([255,12,4,6,0]))
        unsafeEvents.receive(event(popEvent, opcode: 8))
        unsafeEvents.receive(event([0] + RCSPProtocol.field(4, [6] + RCSPProtocol.eqGains(1)!)))
        check("evento truncado, configuração e função alheia não alteram estado", unsafeEvents.eqRaw == ready.eqRaw && unsafeEvents.next() == nil)
        var unidentifiedEvents = RCSPClient()
        unidentifiedEvents.receive(event(popEvent))
        check("evento sem identidade não libera capacidades", unidentifiedEvents.eqRaw == nil && !unidentifiedEvents.canEQ)
        var compact = ready
        compact.refresh(); let compactADV = compact.next()!
        compact.receive(response(compactADV,RCSPProtocol.field(11,[2,0])))
        let compactEQ = compact.next()!
        compact.receive(response(compactEQ,[255]+RCSPProtocol.field(4,[0]+Array(repeating: 0,count: 10))))
        check("resposta real libera ANC compacto", compact.canNoise && compact.noise == .normal)
        compact.setNoise(.anc); let compactWrite = compact.next()!
        check("ANC compacto usa atributo e comprimento corretos", compactWrite.packet.payload == [9,11,65,0,0,0,0,0,0,0])
        compact.receive(response(compactWrite,[0])); let compactRead = compact.next()!
        compact.receive(response(compactRead,RCSPProtocol.field(11,[65,0])))
        check("ANC compacto confirmado por leitura de dois bytes", compact.noise == .anc && !compact.busy && compact.confirmation != nil)
        client.setNoise(.anc)
        let write = client.next()!
        check("ANC usa SetADV tipo 11", write.packet.opcode == 0xc0 && write.packet.payload == [9,11,65,0,0,0,0,0,0,0])
        client.receive(response(write,[0]))
        check("ACK não confirma alteração", client.busy && client.confirmation == nil && client.noise == .normal)
        let readback = client.next()!
        client.receive(response(readback,RCSPProtocol.field(11,anc)))
        check("leitura após escrita confirma ANC", !client.busy && client.noise == .anc && client.confirmation != nil)
        client = ready; client.setGame(true)
        let game = client.next()!
        check("jogo usa valor 2 no perfil antigo", game.packet.payload == [2,5,2])
        client.receive(response(game,[0])); let gameRead = client.next()!
        client.receive(response(gameRead,RCSPProtocol.field(5,[1])))
        check("primeira divergência aguarda nova leitura", !client.failed && client.busy && client.confirmation == nil)
        let gameRetry = client.next()!
        check("reconsulta não repete configuração e aguarda estabilização", gameRetry.packet.opcode == 0xc1 && gameRetry.settleDelay == 0.5)
        client.receive(response(gameRetry,RCSPProtocol.field(5,[1])))
        let gameLast = client.next()!
        client.receive(response(gameLast,RCSPProtocol.field(5,[1])))
        check("divergência persistente não bloqueia sessão", !client.failed && client.canGame && !client.busy && client.confirmation == nil && client.error != nil && client.next() == nil)
        client.setGame(true)
        check("nova ação possível sem reconectar", client.next()?.packet.opcode == 0xc0)
        client = ready; client.setPreset(0)
        client.setPreset(4); let delayedWrite = client.next()!
        client.receive(response(delayedWrite,[])); let oldEQ = client.next()!
        client.receive(response(oldEQ,[255]+RCSPProtocol.field(4,[1]+Array(repeating: 0,count: 10))))
        let freshEQ = client.next()!
        check("EQ antigo provoca somente nova consulta EQ", freshEQ.packet.opcode == 7 && freshEQ.settleDelay == 0.5 && client.confirmation == nil)
        client.receive(response(freshEQ,[255]+RCSPProtocol.field(4,[6]+RCSPProtocol.eqGains(4)!)))
        check("EQ que estabiliza é confirmado sem desconectar", client.preset == 4 && client.confirmation != nil && !client.failed && !client.busy)
        var slowANC = ready
        slowANC.setNoise(.anc); let slowWrite = slowANC.next()!
        slowANC.receive(response(slowWrite,[0])); let oldANC = slowANC.next()!
        slowANC.receive(response(oldANC,RCSPProtocol.field(11,normal)))
        let freshANC = slowANC.next()!
        slowANC.receive(response(freshANC,RCSPProtocol.field(11,anc)))
        check("ANC que estabiliza é confirmado sem repetir escrita", freshANC.packet.opcode == 0xc1 && slowANC.noise == .anc && slowANC.confirmation != nil)
        let flagged: [UInt8] = [0x41,6,0,0,0x40,0,0x27,0xae]
        check("estado real 41 é ANC conforme configuração oficial", RCSPProtocol.validNoiseRecord(flagged) && RCSPProtocol.noise(flagged) == .anc)
        check("troca Normal não reaproveita ganhos da resposta", RCSPProtocol.noiseBytes(.normal, preserving: flagged) == [2,0,0,0,0,0,0,0])
        var extended = ready; extended.refresh(); let extendedRead = extended.next()!
        extended.receive(response(extendedRead,RCSPProtocol.field(11,flagged) + RCSPProtocol.field(5,[1])))
        check("estado ANC 41 não derruba capacidades", extended.noise == .anc && extended.canNoise && extended.canGame && !extended.failed)
        client = ready; client.setPreset(2)
        let eqWrite = client.next()!
        check("EQ usa função pública e atributo 4", eqWrite.packet.opcode == 8 && eqWrite.packet.payload == [255,12,4,255,4,4,3,1,0,0,0,0,0,0])
        client.receive(response(eqWrite,[])); let eqRead = client.next()!
        client.receive(response(eqRead,[255]+RCSPProtocol.field(4,[6]+RCSPProtocol.eqGains(2)!)))
        check("EQ confirmado após nova consulta", client.preset == 2 && client.confirmation != nil)
        var pop = ready; pop.setPreset(1); let popWrite = pop.next()!
        check("Pop envia curva pelo seletor FF do QCY", popWrite.packet.payload == [255,12,4,255,250,5,253,254,5,4,252,5,4,0])
        pop.receive(response(popWrite,[])); let popRead = pop.next()!
        pop.receive(response(popRead,[255]+RCSPProtocol.field(4,[6,250,5,253,254,5,4,252,5,4,0])))
        check("Pop confirma os dez ganhos retornados", pop.preset == 1 && pop.confirmation != nil)
        pop.setPreset(0); let flatWrite = pop.next()!
        check("Padrão envia dez ganhos zero pelo seletor FF", flatWrite.packet.payload == [255,12,4,255]+Array(repeating: 0,count: 10))
        pop.receive(response(flatWrite,[])); let flatRead = pop.next()!
        pop.receive(response(flatRead,[255]+RCSPProtocol.field(4,[6]+Array(repeating: 0,count: 10))))
        check("Padrão confirmado sem depender do banco zero", pop.preset == 0 && pop.confirmation != nil)
        check("banco Jieli 1 não é chamado Pop sem curva correspondente", RCSPProtocol.eqPreset([1,1,1,1,1,1,1,1,1,1,1]) == nil)
        check("modo EQ isolado não comprova curva", RCSPProtocol.eqPreset([6,0,0,0,0,0,0,0,0,0,1]) == nil)
        var ffReadback = ready
        ffReadback.setPreset(1); let ffWrite = ffReadback.next()!
        ffReadback.receive(response(ffWrite, [])); let ffRead = ffReadback.next()!
        ffReadback.receive(response(ffRead, [255] + RCSPProtocol.field(4, [255] + RCSPProtocol.eqGains(1)!)))
        check("retorno customizado FF confirma todos os ganhos", ffReadback.preset == 1 && ffReadback.canEQ && ffReadback.confirmation != nil)
        check("Transparência usa somente modo como clique oficial", RCSPProtocol.noiseBytes(.transparency, preserving: flagged) == [3,0,0,0,0,0,0,0])
        var unchanged = ready
        unchanged.setPreset(1); let unchangedWrite = unchanged.next()!
        unchanged.receive(response(unchangedWrite, [])); let unchangedRead = unchanged.next()!
        unchanged.receive(response(unchangedRead, [255] + RCSPProtocol.field(4, [6,6,7,1,2,255,1,252,250,249,248])))
        check("curva real anterior do relatório não confirma nova escrita", unchanged.confirmation == nil && unchanged.busy && unchanged.preset == nil)
        check("curvas oficiais dentro de seis decibéis", RCSPProtocol.eqCurves.allSatisfy { $0.count == 10 && $0.allSatisfy { (-6...6).contains($0) } })
        check("códigos genéricos ANC não são aceitos como estado T13", RCSPProtocol.noise([0,0]) == nil && RCSPProtocol.noise([1,0]) == nil)
        var custom = ready
        let customGains = [-6,-4,-2,0,2,4,6,3,1,-1]
        custom.setGains(customGains); let customWrite = custom.next()!
        check("curva manual usa FF e dez ganhos assinados", customWrite.packet.payload == [255,12,4,255,250,252,254,0,2,4,6,3,1,255])
        custom.receive(response(customWrite, []))
        check("ACK não confirma curva manual", custom.busy && custom.confirmation == nil)
        let customRead = custom.next()!
        custom.receive(response(customRead, [255] + RCSPProtocol.field(4, [6] + customGains.map { UInt8(bitPattern: Int8($0)) })))
        check("curva manual confirma somente os dez ganhos", !custom.busy && custom.confirmation != nil && custom.preset == nil)
        var invalidCustom = ready
        invalidCustom.setGains([0,0]); invalidCustom.setGains(Array(repeating: 7, count: 10)); invalidCustom.setGains(Array(repeating: -7, count: 10))
        check("quantidade e ganho manual inválidos não enviam comandos", invalidCustom.next() == nil && !invalidCustom.busy)
        var divergentCustom = ready
        divergentCustom.setGains(customGains); let divergentWrite = divergentCustom.next()!
        divergentCustom.receive(response(divergentWrite, []))
        for _ in 0..<3 {
            let query = divergentCustom.next()!
            divergentCustom.receive(response(query, [255] + RCSPProtocol.field(4, [6] + Array(repeating: 0,count: 10))))
        }
        check("curva divergente preserva canal e não confirma", !divergentCustom.failed && !divergentCustom.busy && divergentCustom.confirmation == nil && divergentCustom.error != nil)
        var emptyCustom = ready
        emptyCustom.setGains(customGains); let emptyWrite = emptyCustom.next()!
        emptyCustom.receive(response(emptyWrite, [])); let emptyQuery = emptyCustom.next()!
        emptyCustom.receive(response(emptyQuery, [255]))
        check("consulta EQ sem curva não deixa operação presa", emptyCustom.failed && !emptyCustom.busy)
        client = ready; client.setTouch(258,function: 3)
        let touch = client.next()!
        check("toque altera somente tupla existente", touch.packet.payload == [4,2,1,2,3])
        client.receive(response(touch,[0])); let touchRead = client.next()!
        client.receive(response(touchRead,RCSPProtocol.field(2,[1,2,3])))
        check("toque confirmado após nova consulta", client.touches.first?.function == 3 && client.confirmation != nil)
        client = ready; client.setTouch(999,function:3)
        check("gesto não anunciado bloqueado", client.next() == nil)
        client.setTouch(258,function:99)
        check("função desconhecida bloqueada", client.next() == nil)
        client.setPreset(6)
        check("modo EQ não mapeado bloqueado", client.next() == nil)
        client = ready; client.setGame(true); _ = client.next(); client.timeout()
        check("timeout de escrita não repete comando", client.failed && client.next() == nil && client.confirmation == nil)
        client.refresh(); let recoveryADV = client.next()!
        check("atualizar recupera sessão sem repetir escrita", !client.failed && recoveryADV.packet.opcode == 0xc1 && !client.canNoise && !client.canEQ)
        client.receive(response(recoveryADV,advPayload)); let recoveryEQ = client.next()!
        client.receive(response(recoveryEQ,[255]+RCSPProtocol.field(4,[0]+Array(repeating: 0,count: 10))))
        check("atualização restaura somente estados consultados", client.canNoise && client.canGame && client.canEQ && client.error == nil && client.confirmation == nil)
        var missingIdentity = RCSPClient(); missingIdentity.start(); _ = missingIdentity.next(); missingIdentity.timeout(); missingIdentity.refresh()
        check("atualizar não contorna identidade ausente", missingIdentity.failed && missingIdentity.next() == nil)
        client = ready; client.setNoise(.anc); let rejected = client.next()!
        client.receive(response(rejected,[],status: 1))
        check("recusa pelo fone bloqueia alterações", client.failed && !client.canNoise)
        client = ready; client.setNoise(.anc); let noResult = client.next()!
        client.receive(response(noResult,[]))
        check("ACK ADV sem resultado não é sucesso", client.failed)
        client = ready; client.setGame(true); let emptyRead = client.next()!
        client.receive(response(emptyRead,[0])); let read = client.next()!
        client.receive(response(read,RCSPProtocol.field(11,normal)))
        check("leitura sem atributo solicitado rejeitada", client.failed)
        client.start(); let upgrade = client.next()!
        client.receive(response(upgrade,RCSPProtocol.field(5,[2,64])+RCSPProtocol.field(9,[1])))
        check("modo atualização não libera controles", client.failed && !client.ready)
        client.start(); let privateInfo = client.next()!
        client.receive(response(privateInfo, infoPayload + RCSPProtocol.field(2,[0xde,0xad,0xbe,0xef,0x12,0x34])))
        check("conteúdo privado não vai ao diagnóstico", !client.takeLogs().joined().contains("DE AD"))
        return tests
    }
}
