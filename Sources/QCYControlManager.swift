import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
@preconcurrency import CoreBluetooth

struct ControlCandidate: Identifiable, Sendable {
    let id: UUID
    let name: String
    let signal: Int
    var unavailable = false
    var source = "Anúncio BLE"
}

private struct ControlSnapshot: Sendable {
    let status: String
    let candidates: [ControlCandidate]
    let awaitingConnection: Bool
    let gains: [Int]?
    let battery: RCSPBattery?
    let scanning: Bool
    let connected: Bool
    let firmware: String?
    let noise: NoiseMode?
    let game: Bool?
    let preset: UInt8?
    let pending: String?
    let error: String?
    let lastConfirmation: String?
    let canNoise: Bool
    let canGame: Bool
    let canEQ: Bool
    let canObserve: Bool
    let observing: Bool
    let rcsp: Bool
    let touches: [RCSPTouch]
    let canTouch: Bool
    let report: String
}

// CoreBluetooth objects, delegates and deadlines share one dedicated serial queue.
// No CoreBluetooth operation is synchronously performed by a SwiftUI button.
private final class QCYControlEngine: NSObject, @unchecked Sendable, CBCentralManagerDelegate, CBPeripheralDelegate {
    let queue = DispatchQueue(label: "br.local.QCYControl.ble", qos: .userInitiated)
    private let sink: @Sendable (ControlSnapshot) -> Void
    private var publishQueued = false
    init(sink: @escaping @Sendable (ControlSnapshot) -> Void) { self.sink = sink; super.init() }
    private func publishSoon() {
        guard !publishQueued else { return }
        publishQueued = true
        queue.async { self.publishQueued = false; self.publish() }
    }
    private func publish() {
        sink(ControlSnapshot(status: status, candidates: candidates, awaitingConnection: peripheral != nil && !connected, gains: rcspClient.eqRaw.map { $0.dropFirst().map { Int(Int8(bitPattern: $0)) } }, battery: connected && rcspActive ? rcspClient.battery : nil, scanning: scanning, connected: connected,
            firmware: firmware, noise: noise, game: game, preset: preset, pending: pending, error: error,
            lastConfirmation: lastConfirmation, canNoise: canNoise, canGame: canGame, canEQ: canEQ,
            canObserve: canObserve, observing: observing, rcsp: rcspActive, touches: rcspClient.touches, canTouch: canTouch, report: report))
    }
    private func later(_ seconds: Double, _ action: @escaping @Sendable (QCYControlEngine) -> Void) -> DispatchWorkItem {
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            action(self)
        }
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    var status = "Conecte os controles para consultar as funções dos fones." { didSet { publishSoon() } }
    var candidates: [ControlCandidate] = [] { didSet { publishSoon() } }
    var scanning = false { didSet { publishSoon() } }
    var connected = false { didSet { publishSoon() } }
    var firmware: String? { didSet { publishSoon() } }
    var noise: NoiseMode? { didSet { publishSoon() } }
    var game: Bool? { didSet { publishSoon() } }
    var preset: UInt8? { didSet { publishSoon() } }
    var pending: String? { didSet { publishSoon() } }
    var error: String? { didSet { publishSoon() } }
    var lastConfirmation: String? { didSet { publishSoon() } }
    private var central: CBCentralManager?
    private var automatic = false
    private var skipRemembered = false
    private var manuallyPaused = false
    private var reconnectAttempts = 0
    private var reconnectTask: DispatchWorkItem?
    private var savedID: UUID? { UserDefaults.standard.string(forKey: "controlPeripheralID").flatMap(UUID.init(uuidString:)) }
    func startAutomatic() {
        guard !manuallyPaused, !connected, peripheral == nil, !scanning, !wantsScan else { return }
        automatic = true; reconnectAttempts = 0; skipRemembered = false
        log("Conexão automática solicitada pelo aplicativo.")
        wantsScan = true; autoProbe = true
        if central == nil { central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
        else { beginScanIfReady() }
    }
    func systemConnectionArrived() {
        manuallyPaused = false
        reconnectTask?.cancel(); reconnectTask = nil
        startAutomatic()
    }
    private func retryConnection() {
        guard automatic, reconnectAttempts < 3 else { return }
        skipRemembered = savedID == nil
        reconnectAttempts += 1
        let delay = Double(reconnectAttempts * 5)
        log("Reconexão automática agendada em \(Int(delay)) s (\(reconnectAttempts)/3).")
        reconnectTask?.cancel()
        reconnectTask = later(delay) { engine in engine.wantsScan = true; engine.autoProbe = true; engine.beginScanIfReady() }
    }
    private var wantsScan = false
    private var autoProbe = false
    private var seekingControl = false
    private var handoffCount = 0
    private var rejected = Set<UUID>()
    private var observedProducts = Set<UInt16>()
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var products: [UUID: UInt16] = [:]
    private var rcspActive = false
    private var rcspClient = RCSPClient()
    private var rcspTimeout: DispatchWorkItem?
    private var rcspCommand: CBCharacteristic?
    private var rcspNotify: CBCharacteristic?
    private var rcspStarted = false
    private var decoder = QCYFrameDecoder()
    private var sessionTimeout: DispatchWorkItem?
    private var operationTimeout: DispatchWorkItem?
    private var queryTask: DispatchWorkItem?
    private var trace: [String] = []
    private var notifyReady = false
    private var identityVerified = false
    private var profileConfirmed = false
    private var inspectedServices = Set<CBUUID>()
    private var passiveCharacteristic: CBCharacteristic?
    private var observationTimeout: DispatchWorkItem?
    private var observedFrames = 0
    var observing = false { didSet { publishSoon() } }
    var canObserve: Bool { connected && identityVerified && !profileConfirmed && !rcspActive && passiveCharacteristic != nil }

    private var inspectionsRemaining = 0
    private let inspectionReads = Set([CBUUID(string: "00000007-0000-1000-8000-00805f9b34fb"), CBUUID(string: "00000008-0000-1000-8000-00805f9b34fb"), CBUUID(string: "2A26"), CBUUID(string: "2A24"), CBUUID(string: "2A19")])
    private var queried = Set<UInt8>()
    private var expected: (opcode: UInt8, value: UInt8)?
    private var querySent = false
    private var activeWrite: Write?
    private var writeQueue: [Write] = []
    private var sending = false
    private var generation = 0
    private var failureSuppression = false
    private let service = CBUUID(string: "A001")
    private let commandID = CBUUID(string: "1001")
    private let notifyID = CBUUID(string: "1002")
    private let versionID = CBUUID(string: "00000007-0000-1000-8000-00805f9b34fb")
    private let eqID = CBUUID(string: "0000000B-0000-1000-8000-00805f9b34fb")
    private struct Write: @unchecked Sendable { let data: Data; let characteristic: CBCharacteristic; let control: Bool }
    var validated: Bool { connected && identityVerified && profileConfirmed && firmware == "2.4.0" }
    var canNoise: Bool { if rcspActive { return connected && notifyReady && rcspClient.canNoise }; return validated && noise != nil && notifyReady && writable(commandID) && !failureSuppression }
    var canGame: Bool { if rcspActive { return connected && notifyReady && rcspClient.canGame }; return validated && game != nil && notifyReady && writable(commandID) && !failureSuppression }
    var canEQ: Bool { if rcspActive { return connected && notifyReady && rcspClient.canEQ }; return validated && preset != nil && writable(eqID) && !failureSuppression }
    var canTouch: Bool { rcspActive && connected && notifyReady && rcspClient.canTouch }
    var busy: Bool { pending != nil }
    private func writable(_ id: CBUUID) -> Bool {
        guard let c = characteristics[id] else { return false }
        return c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)
    }
    private func log(_ text: String) {
        trace.append("[\(ISO8601DateFormatter().string(from: Date()))] " + text)
        if trace.count > 2000 { trace.removeFirst(trace.count - 2000) }
    }
    func startScan(probe: Bool = true) {
        disconnect()
        manuallyPaused = false; automatic = true; skipRemembered = true; reconnectAttempts = 0
        autoProbe = true
        seekingControl = false; handoffCount = 0; rejected = []; observedProducts = []
        wantsScan = true; candidates = []; peripherals = [:]; products = [:]; error = nil; failureSuppression = false
        if central == nil { central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
        else { beginScanIfReady() }
    }
    private func beginScanIfReady() {
        guard wantsScan, central?.state == .poweredOn else { return }
        if automatic, !skipRemembered, let id = savedID,
           let remembered = central?.retrievePeripherals(withIdentifiers: [id]).first {
            wantsScan = false
            peripherals[id] = remembered; products[id] = QCYProtocol.targetVendorID
            if !candidates.contains(where: { $0.id == id }) { candidates.append(ControlCandidate(id: id, name: remembered.name ?? "QCY T13 ANC", signal: 0, source: "Fone identificado anteriormente")) }
            log("Recuperando conexão BLE previamente identificada, sem varredura.")
            connect(id, waitForReturn: true); return
        }
        wantsScan = false; scanning = true
        status = "Buscando o canal de controle dos QCY…"
        log("Varredura BLE iniciada (15 s).")
        // Connected GATT peers can be known to the system without advertising.
        // Query the exact documented service; revalidate its profile after connect.
        let existing = central?.retrieveConnectedPeripherals(withServices: [service]) ?? []
        let eligible = existing.filter { QCYProtocol.targetName($0.name ?? "") }
        log("Consulta de A001 já conectado ao sistema: \(existing.count) retornados, \(eligible.count) com nome T13 ANC exato.")
        for found in eligible where peripherals[found.identifier] == nil {
            peripherals[found.identifier] = found
            candidates.insert(ControlCandidate(id: found.identifier, name: found.name ?? "QCY T13 ANC", signal: 0, source: "A001 já conectado ao Mac"), at: 0)
        }
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        sessionTimeout?.cancel()
        sessionTimeout = later(15) { engine in
            engine.central?.stopScan(); engine.scanning = false
            let eligible = engine.candidates.filter { !engine.rejected.contains($0.id) }
            if (engine.autoProbe || engine.seekingControl), eligible.count == 1, let candidate = eligible.first {
                engine.connect(candidate.id)
                return
            }
            if engine.seekingControl {
                engine.status = eligible.isEmpty
                    ? "Não foi encontrado outro canal de controle. Copie o diagnóstico abaixo para investigar os serviços disponíveis."
                    : "Foram encontradas outras conexões. Selecione a conexão dos seus fones."
                engine.seekingControl = false
                return
            }
            if engine.automatic { engine.retryConnection() }
            engine.status = engine.candidates.isEmpty ? "Canal de controle não encontrado. Mantenha os fones ligados e feche o app QCY no celular antes de tentar novamente." : "Selecione seus fones para conectar os controles."
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Estado CoreBluetooth: \(central.state.rawValue).")
        switch central.state {
        case .poweredOn:
            if automatic && !manuallyPaused && peripheral == nil { wantsScan = true; autoProbe = true }
            beginScanIfReady()
        case .unauthorized: status = "Permita Bluetooth para QCY Control em Ajustes do Sistema → Privacidade e Segurança → Bluetooth."; invalidate()
        case .poweredOff: status = "O Bluetooth do Mac está desligado."; peripheral = nil; invalidate()
        case .unsupported: status = "Este adaptador não disponibiliza Bluetooth LE."; invalidate()
        case .resetting: status = "Aguardando o retorno do Bluetooth do Mac…"; peripheral = nil; invalidate()
        default: status = "Aguardando o Bluetooth do Mac…"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "QCY T13 ANC"
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        // An unnamed peripheral must identify itself by the exact product ID.
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString).joined(separator: ", ")
        if let product = QCYProtocol.vendorID(manufacturer), !observedProducts.contains(product) {
            observedProducts.insert(product)
            log("Anúncio QCY: produto \(product), serviços anunciados: \(services.isEmpty ? "nenhum" : services).")
        }
        guard QCYProtocol.target(name: advertisedName, manufacturer: manufacturer) else { return }
        if let product = QCYProtocol.vendorID(manufacturer) { products[peripheral.identifier] = product }
        if automatic, QCYProtocol.vendorID(manufacturer) == QCYProtocol.targetVendorID {
            peripherals[peripheral.identifier] = peripheral
            if !candidates.contains(where: { $0.id == peripheral.identifier }) { candidates.append(ControlCandidate(id: peripheral.identifier, name: name, signal: RSSI.intValue)) }
            connect(peripheral.identifier); return
        }
        guard peripherals[peripheral.identifier] == nil else { return }
        peripherals[peripheral.identifier] = peripheral
        candidates.append(ControlCandidate(id: peripheral.identifier, name: name, signal: RSSI.intValue))
        log("Candidato: serviços anunciados \(services.isEmpty ? "nenhum" : services).")
        log("Candidato T13 ANC encontrado; identidade por \(QCYProtocol.vendorID(manufacturer) == QCYProtocol.targetVendorID ? "produto" : "nome exato").")
    }
    func connect(_ id: UUID, waitForReturn: Bool = false) {
        guard !rejected.contains(id), let candidate = peripherals[id] else { return }
        sessionTimeout?.cancel(); central?.stopScan(); scanning = false
        invalidate(); error = nil
        automatic = true; manuallyPaused = false
        peripheral = candidate; identityVerified = true; candidate.delegate = self
        status = "Conectando os controles…"; log("Conexão BLE solicitada.")
        central?.connect(candidate)
        if waitForReturn {
            status = "Aguardando os fones. Os controles serão conectados automaticamente."
            log("Conexão ao periférico conhecido mantida pelo CoreBluetooth até os fones voltarem; sem varredura periódica.")
            return
        }
        sessionTimeout = later(18) { engine in
            engine.error = "Os fones não concluíram a conexão de controle. Feche o app QCY no celular e tente novamente."
            let old = engine.peripheral; engine.peripheral = nil; engine.invalidate()
            if let old { engine.central?.cancelPeripheralConnection(old) }
            engine.retryConnection()
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        sessionTimeout?.cancel()
        sessionTimeout = later(18) { engine in
            guard !engine.notifyReady else { return }
            let old = engine.peripheral; engine.peripheral = nil; engine.invalidate()
            if let old { engine.central?.cancelPeripheralConnection(old) }
            engine.retryConnection()
        }
        reconnectAttempts = 0
        connected = true; status = "Consultando funções do firmware…"; log("Conexão BLE estabelecida.")
        // Enumerate all primary services read-only so absence and alternate protocols
        // can be diagnosed instead of treating every empty filtered result as absence.
        peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        self.error = "Não foi possível conectar o canal de controle."; status = "Controles desconectados."
        log("Falha de conexão BLE."); invalidate(); self.peripheral = nil; retryConnection()
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        status = "Conexão de controle encerrada. Você pode tentar novamente."
        log("Conexão BLE encerrada."); invalidate(); self.peripheral = nil; retryConnection()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error {
            let ns = error as NSError
            log("Erro de descoberta: \(ns.domain) / \(ns.code).")
            self.error = "Não foi possível consultar os serviços Bluetooth. Copie o diagnóstico para investigar."
            disconnect(); return
        }
        let offered = (peripheral.services ?? []).map { $0.uuid.uuidString }.sorted()
        log("Serviços oferecidos: \(offered.isEmpty ? "nenhum" : offered.joined(separator: ", ")).")
        guard let found = peripheral.services?.first(where: { $0.uuid == service }) else {
            if let alternate = peripheral.services?.first(where: { QCYProtocol.serviceRole($0.uuid.uuidString) == .inspectionOnly }) {
                if RCSPProtocol.legacyProduct(products[peripheral.identifier]) {
                    rcspActive = true
                    status = "Canal Jieli encontrado. Preparando consulta RCSP…"
                    log("Perfil Jieli legado selecionado pelo produto 18290 e serviço A002.")
                    peripheral.discoverCharacteristics([CBUUID(string: "0001"), CBUUID(string: "0002")], for: alternate)
                    return
                }
                sessionTimeout?.cancel()
                status = "Serviço A002 encontrado. Consultando características, sem comandos de configuração…"
                log("A002: inspeção somente de leitura; perfil de comandos não confirmado.")
                inspectService(alternate, peripheral: peripheral)
                sessionTimeout = later(12) { engine in
                    guard !engine.profileConfirmed, !engine.observing else { return }
                    engine.status = "Serviço A002 inspecionado. Copie o diagnóstico para identificar o protocolo."
                }
                return
            }
            let id = peripheral.identifier
            rejected.insert(id)
            if let index = candidates.firstIndex(where: { $0.id == id }) { candidates[index].unavailable = true }
            // Some QCY variants advertise a separate control endpoint after a BLE
            // connection is closed. Retry discovery once, without touching A2DP.
            if handoffCount == 0 {
                handoffCount += 1
                let old = self.peripheral
                self.peripheral = nil
                invalidate()
                if let old { central?.cancelPeripheralConnection(old) }
                seekingControl = true; self.error = nil
                status = "Esta conexão não oferece A001. Buscando outra conexão de controle dos fones…"
                log("A001 ausente; uma nova busca será realizada após encerrar apenas a conexão BLE.")
                sessionTimeout = later(0.8) { engine in engine.wantsScan = true; engine.beginScanIfReady() }
            } else {
                self.error = "O serviço de controle A001 não foi encontrado nas conexões testadas. Copie o diagnóstico abaixo."
                disconnect()
            }
            return
        }
        configureDocumentedService(found, peripheral: peripheral)
    }
    private func configureDocumentedService(_ found: CBService, peripheral: CBPeripheral) {
        guard QCYProtocol.serviceRole(found.uuid.uuidString) == .documentedControl, !profileConfirmed else { return }
        profileConfirmed = true
        log("Serviço A001 confirmado.")
        status = "Serviço de controle A001 encontrado. Consultando firmware…"
        peripheral.discoverCharacteristics([commandID, notifyID, versionID, eqID], for: found)
    }
    private func inspectService(_ found: CBService, peripheral: CBPeripheral) {
        guard !inspectedServices.contains(found.uuid), inspectedServices.count < 8 else { return }
        inspectedServices.insert(found.uuid)
        inspectionsRemaining += 2
        peripheral.discoverIncludedServices(nil, for: found)
        peripheral.discoverCharacteristics(nil, for: found)
    }
    private func inspectionFinished() {
        inspectionsRemaining = max(0, inspectionsRemaining - 1)
        if inspectionsRemaining == 0, !profileConfirmed, !observing {
            sessionTimeout?.cancel()
            status = "Características do A002 consultadas. Copie o diagnóstico; os comandos deste serviço ainda não estão confirmados."
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, inspectedServices.contains(service.uuid) else { return }
        defer { inspectionFinished() }
        if let error {
            let ns = error as NSError
            log("Serviços incluídos em \(service.uuid.uuidString): erro \(ns.domain) / \(ns.code).")
            return
        }
        let included = service.includedServices ?? []
        log("Incluídos em \(service.uuid.uuidString): \(included.isEmpty ? "nenhum" : included.map { $0.uuid.uuidString }.joined(separator: ", ")).")
        for child in included {
            if QCYProtocol.serviceRole(child.uuid.uuidString) == .documentedControl {
                configureDocumentedService(child, peripheral: peripheral)
            } else { inspectService(child, peripheral: peripheral) }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if rcspActive, service.uuid == CBUUID(string: "A002") {
            guard error == nil,
                  let write = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "0001") && $0.properties.contains(.writeWithoutResponse) }),
                  let notify = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "0002") && $0.properties.contains(.notify) }) else {
                rcspClient.fail("O canal A002 não oferece as características RCSP esperadas."); syncRCSP(); return
            }
            rcspCommand = write; rcspNotify = notify
            log("RCSP: escrita 0001, notificações 0002. Nenhuma configuração inicial enviada.")
            peripheral.setNotifyValue(true, for: notify)
            return
        }
        if inspectedServices.contains(service.uuid), QCYProtocol.serviceRole(service.uuid.uuidString) != .documentedControl {
            defer { inspectionFinished() }
            if let error {
                let ns = error as NSError
                log("Características \(service.uuid.uuidString): erro \(ns.domain) / \(ns.code).")
                return
            }
            let listed = service.characteristics ?? []
            if QCYProtocol.serviceRole(service.uuid.uuidString) == .inspectionOnly,
               listed.contains(where: { $0.uuid == CBUUID(string: "0001") && $0.properties.contains(.writeWithoutResponse) }),
               let notify = listed.first(where: { $0.uuid == CBUUID(string: "0002") && $0.properties.contains(.notify) }) {
                passiveCharacteristic = notify
            }
            log("Serviço \(service.uuid.uuidString): \(listed.count) características.")
            for c in listed {
                var flags: [String] = []
                if c.properties.contains(.read) { flags.append("ler") }
                if c.properties.contains(.write) { flags.append("escrever") }
                if c.properties.contains(.writeWithoutResponse) { flags.append("escrever sem resposta") }
                if c.properties.contains(.notify) { flags.append("notificar") }
                if c.properties.contains(.indicate) { flags.append("indicar") }
                log("Inspeção \(service.uuid.uuidString) / \(c.uuid.uuidString): \(flags.joined(separator: ", ")) [\(c.properties.rawValue)].")
                // Do not read unknown payloads, serial-number characteristics, or
                // subscribe to notifications on an unverified profile.
                if inspectionReads.contains(c.uuid), c.properties.contains(.read) { peripheral.readValue(for: c) }
            }
            return
        }
        guard error == nil, profileConfirmed, QCYProtocol.serviceRole(service.uuid.uuidString) == .documentedControl else { return }
        for c in service.characteristics ?? [] {
            characteristics[c.uuid] = c
            log("GATT \(c.uuid.uuidString), propriedades \(c.properties.rawValue).")
        }
        guard let version = characteristics[versionID], version.properties.contains(.read) else {
            self.error = "O firmware não pode ser confirmado por este canal. Escritas bloqueadas."; sessionTimeout?.cancel(); return
        }
        peripheral.readValue(for: version)
        if let notify = characteristics[notifyID], notify.properties.contains(.notify) || notify.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: notify)
        }
    }
    func observe() {
        guard canObserve, !observing, let passiveCharacteristic else { return }
        observedFrames = 0; observing = true; error = nil
        status = "Observando A002 por 15 segundos. Você pode mudar o modo pelo toque dos fones."
        log("Observação A002 iniciada pelo usuário: somente assinatura GATT padrão; sem comandos proprietários.")
        peripheral?.setNotifyValue(true, for: passiveCharacteristic)
        observationTimeout?.cancel()
        observationTimeout = later(15) { engine in engine.stopObservation() }
    }
    func stopObservation() {
        guard observing else { return }
        observing = false; observationTimeout?.cancel()
        if let passiveCharacteristic { peripheral?.setNotifyValue(false, for: passiveCharacteristic) }
        status = "Observação encerrada: \(observedFrames) notificações. Copie o diagnóstico."
        log("Observação A002 encerrada: \(observedFrames) notificações; nenhum comando proprietário enviado.")
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if self.peripheral === peripheral, rcspActive, characteristic === rcspNotify {
            notifyReady = error == nil && characteristic.isNotifying
            guard notifyReady else { rcspClient.fail("Não foi possível ativar as respostas RCSP."); syncRCSP(); return }
            guard !rcspStarted else { return }
            rcspStarted = true; sessionTimeout?.cancel()
            log("Notificações RCSP ativas; iniciando consulta de informações (sem configurar os fones).")
            rcspClient.start(); sendNextRCSP(); return
        }
        if self.peripheral === peripheral, characteristic === passiveCharacteristic {
            if error != nil {
                stopObservation(); self.error = "Não foi possível observar as notificações do A002."
            } else { log("Assinatura A002: \(characteristic.isNotifying ? "ativa" : "encerrada").") }
            return
        }
        guard self.peripheral === peripheral, characteristic.uuid == notifyID else { return }
        notifyReady = error == nil && characteristic.isNotifying
        log("Notificações: \(notifyReady ? "ativas" : "indisponíveis").")
        beginQueries()
    }
    private func beginQueries() {
        guard validated else { return }
        sessionTimeout?.cancel()
        status = "Canal conectado. Funções liberadas após resposta dos fones."
        if let eq = characteristics[eqID], eq.properties.contains(.read) { peripheral?.readValue(for: eq) }
        guard notifyReady, writable(commandID) else { return }
        for opcode: UInt8 in [0x0c, 0x09] {
            guard !queried.contains(opcode) else { continue }
            enqueueQuery(opcode)
        }
    }
    private func enqueueQuery(_ opcode: UInt8) {
        guard validated, let data = QCYProtocol.query(opcode), let c = characteristics[commandID] else { return }
        queried.insert(opcode)
        writeQueue.append(Write(data: data, characteristic: c, control: false)); pump()
    }
    private func enqueueControl(_ data: Data, characteristic: CBCharacteristic) {
        writeQueue.append(Write(data: data, characteristic: characteristic, control: true)); pump()
    }
    private func pump() {
        guard !sending, connected, let peripheral, !writeQueue.isEmpty else { return }
        let next = writeQueue[0]
        let type: CBCharacteristicWriteType = next.characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
        guard next.data.count <= peripheral.maximumWriteValueLength(for: type) else {
            failOperation("O canal não aceita este tamanho de comando."); return
        }
        sending = true; activeWrite = next; writeQueue.removeFirst()
        if next.data.count == 5, next.data[2] == 0xfe, let expected, next.data[4] == expected.opcode { querySent = true }
        peripheral.writeValue(next.data, for: next.characteristic, type: type)
        log("TX \(next.characteristic.uuid.uuidString): \(next.data.map { String(format: "%02X", $0) }.joined(separator: " ")).")
        if type == .withoutResponse { finishWrite(error: nil) }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { if self.peripheral === peripheral { pump() } }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, activeWrite?.characteristic === characteristic else { return }
        finishWrite(error: error)
    }
    private func finishWrite(error: Error?) {
        let sent = activeWrite; activeWrite = nil
        if error != nil { sending = false; failOperation("O fone recusou a escrita do comando."); return }
        queryTask?.cancel()
        queryTask = later(rcspActive ? 0.03 : 0.35) { engine in
            engine.sending = false
            if sent?.control == true, let expected = engine.expected {
                if expected.opcode == 0x0b, let eq = engine.characteristics[engine.eqID] {
                    engine.querySent = true; engine.peripheral?.readValue(for: eq)
                } else { engine.enqueueQuery(expected.opcode) }
            }
            engine.pump()
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if rcspActive, characteristic === rcspNotify {
            guard error == nil, let value = characteristic.value else {
                rcspClient.fail("Falha ao receber a resposta RCSP."); syncRCSP(); return
            }
            rcspClient.receive(value); sendNextRCSP(); return
        }
        if characteristic === passiveCharacteristic, observing {
            guard error == nil, let value = characteristic.value else { log("Falha ao receber notificação A002."); return }
            observedFrames += 1
            // Preserve data only for this explicit, bounded local diagnostic.
            // No parser, setting, reset, handshake or firmware write is inferred.
            let raw = value.prefix(128).map { String(format: "%02X", $0) }.joined(separator: " ")
            log("A002 RX #\(observedFrames): \(raw)\(value.count > 128 ? " [truncado]" : "").")
            return
        }
        if characteristic.service?.uuid != service {
            guard inspectionReads.contains(characteristic.uuid) else { return }
            guard error == nil, let value = characteristic.value else {
                log("Falha na leitura de inspeção \(characteristic.uuid.uuidString).")
                return
            }
            // Only version/model/battery fields from an explicit read allowlist.
            if value.count <= 64 {
                log("Leitura de inspeção \(characteristic.uuid.uuidString): \(value.map { String(format: "%02X", $0) }.joined(separator: " ")).")
            } else { log("Leitura de inspeção \(characteristic.uuid.uuidString): formato longo omitido.") }
            return
        }
        guard error == nil, let value = characteristic.value else {
            log("Falha na leitura GATT \(characteristic.uuid.uuidString).")
            if expected != nil { failOperation("Não foi possível confirmar a alteração no fone.") }
            return
        }
        if characteristic.uuid == versionID {
            firmware = QCYProtocol.firmware(value)
            log("Firmware: \(firmware ?? "formato não reconhecido").")
            guard firmware == "2.4.0" else {
                self.error = "Firmware diferente de 2.4.0 ou formato não reconhecido. Controles bloqueados."; sessionTimeout?.cancel(); return
            }
            beginQueries()
        } else if characteristic.uuid == eqID {
            guard validated else { return }
            preset = QCYProtocol.presetValue(value)
            log("EQ: \(value.map { String(format: "%02X", $0) }.joined(separator: " ")).")
            if let preset { confirm(opcode: 0x0b, value: preset) }
        } else if characteristic.uuid == notifyID {
            for command in decoder.consume(value) {
                guard validated, queried.contains(command.opcode) else { continue }
                log("RX \(String(format: "%02X", command.opcode)): \(command.parameters.map { String(format: "%02X", $0) }.joined(separator: " ")).")
                if command.opcode == 0x0c, let mode = QCYProtocol.noiseValue(command.parameters) {
                    noise = mode; confirm(opcode: command.opcode, value: mode.rawValue)
                } else if command.opcode == 9, let enabled = QCYProtocol.gameValue(command.parameters) {
                    game = enabled; confirm(opcode: command.opcode, value: enabled ? 1 : 2)
                }
            }
        }
    }
    private func beginOperation(_ title: String, opcode: UInt8, value: UInt8) {
        pending = title; expected = (opcode, value); querySent = false; error = nil; lastConfirmation = nil
        operationTimeout?.cancel()
        operationTimeout = later(6) { engine in
            guard engine.expected != nil else { return }
            engine.failOperation("O fone não confirmou a alteração. Reconecte os controles antes de tentar novamente.")
        }
    }
    private func confirm(opcode: UInt8, value: UInt8) {
        guard let expected, querySent, expected.opcode == opcode else { return }
        guard expected.value == value else { failOperation("O fone informou um valor diferente do solicitado. Reconecte os controles."); return }
        log("Leitura após escrita confirmada.")
        lastConfirmation = "Alteração confirmada pelos fones."
        operationTimeout?.cancel(); pending = nil; self.expected = nil; querySent = false
    }
    private func failOperation(_ message: String) {
        if rcspActive { rcspClient.fail(message); syncRCSP() }
        error = message; pending = nil; expected = nil; querySent = false; failureSuppression = true
        operationTimeout?.cancel(); writeQueue = []; log("Operação interrompida; sem confirmação.")
    }
    func setNoise(_ mode: NoiseMode) {
        if rcspActive { guard !busy else { return }; rcspClient.setNoise(mode); sendNextRCSP(); return }
        guard canNoise, !busy, let c = characteristics[commandID], noise != mode else { return }
        beginOperation("Alterando cancelamento de ruído…", opcode: 0x0c, value: mode.rawValue)
        enqueueControl(QCYProtocol.noise(mode), characteristic: c)
    }
    func setGame(_ enabled: Bool) {
        if rcspActive { guard !busy else { return }; rcspClient.setGame(enabled); sendNextRCSP(); return }
        guard canGame, !busy, let c = characteristics[commandID], game != enabled else { return }
        beginOperation("Alterando modo jogo…", opcode: 9, value: enabled ? 1 : 2)
        enqueueControl(QCYProtocol.game(enabled), characteristic: c)
    }
    func setPreset(_ value: UInt8) {
        if rcspActive { guard !busy else { return }; rcspClient.setPreset(value); sendNextRCSP(); return }
        guard canEQ, !busy, value < QCYProtocol.presets.count, preset != value, let eq = characteristics[eqID] else { return }
        beginOperation("Aplicando equalizador…", opcode: 0x0b, value: value)
        enqueueControl(Data([value]), characteristic: eq)
    }
    func setGains(_ gains: [Int]) {
        guard rcspActive, !busy else { return }
        rcspClient.setGains(gains); sendNextRCSP()
    }
    func setTouch(_ id: Int, function: UInt8) {
        guard rcspActive, !busy else { return }
        rcspClient.setTouch(id, function: function); sendNextRCSP()
    }
    func refreshControls() {
        guard rcspActive, connected, notifyReady, !busy else { return }
        rcspClient.refresh(); sendNextRCSP()
    }
    func refreshBattery() {
        guard rcspActive, connected, notifyReady else { return }
        rcspClient.refreshBattery(); sendNextRCSP()
    }
    private func sendNextRCSP() {
        guard rcspActive, connected, notifyReady else { return }
        if let request = rcspClient.next() {
            rcspTimeout?.cancel()
            if request.settleDelay > 0 {
                log("RCSP: aguardando 500 ms antes da leitura de confirmação; sem repetir escrita.")
                _ = later(request.settleDelay) { engine in
                    guard engine.rcspClient.current?.packet.sequence == request.packet.sequence else { return }
                    engine.submitRCSP(request)
                }
            } else { submitRCSP(request) }
        } else if rcspClient.current == nil { rcspTimeout?.cancel() }
        syncRCSP()
    }
    private func submitRCSP(_ request: RCSPClient.Request) {
        guard rcspActive, connected, notifyReady, let characteristic = rcspCommand, let peripheral else { return }
        let data = request.packet.data
        let maximum = min(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        guard maximum > 0 else { rcspClient.fail("Canal RCSP sem capacidade de escrita."); syncRCSP(); return }
        for offset in stride(from: 0, to: data.count, by: maximum) {
            writeQueue.append(Write(data: data.subdata(in: offset..<min(offset + maximum, data.count)), characteristic: characteristic, control: false))
        }
        rcspTimeout?.cancel()
        rcspTimeout = later(4) { engine in
            guard engine.rcspClient.current?.packet.sequence == request.packet.sequence else { return }
            engine.rcspClient.timeout(); engine.sendNextRCSP()
        }
        pump()
    }
    private func syncRCSP() {
        for line in rcspClient.takeLogs() { log(line) }
        if rcspClient.infoConfirmed, let id = peripheral?.identifier {
            UserDefaults.standard.set(id.uuidString, forKey: "controlPeripheralID")
        }
        firmware = rcspClient.firmware; noise = rcspClient.noise; game = rcspClient.game; preset = rcspClient.preset
        error = rcspClient.error; lastConfirmation = rcspClient.confirmation
        pending = rcspClient.current != nil ? (rcspClient.busy ? "Aguardando confirmação dos fones…" : "Consultando funções RCSP…") : nil
        if rcspClient.failed {
            pending = nil; writeQueue = []; rcspTimeout?.cancel()
            status = "A operação não foi confirmada. Atualize as funções para consultar novamente sem desconectar."
        } else if rcspClient.current != nil {
            status = "Canal RCSP conectado. Consultando respostas dos fones…"
        } else {
            status = "Canal RCSP conectado. Funções liberadas conforme as respostas dos fones."
        }
        publishSoon()
    }
    private func invalidate() {
        rcspTimeout?.cancel(); rcspActive = false; rcspStarted = false
        rcspClient = RCSPClient(); rcspCommand = nil; rcspNotify = nil
        generation += 1; sessionTimeout?.cancel(); operationTimeout?.cancel(); queryTask?.cancel()
        scanning = false; connected = false; noise = nil; game = nil; preset = nil; firmware = nil
        notifyReady = false; identityVerified = false; profileConfirmed = false
        observationTimeout?.cancel(); passiveCharacteristic = nil; observing = false; observedFrames = 0
        inspectedServices = []; inspectionsRemaining = 0
        pending = nil; expected = nil; querySent = false
        queried = []; characteristics = [:]; decoder = QCYFrameDecoder(); writeQueue = []; activeWrite = nil; sending = false
        lastConfirmation = nil
    }
    func disconnect() {
        manuallyPaused = true
        automatic = false; reconnectTask?.cancel(); reconnectTask = nil
        wantsScan = false; central?.stopScan()
        error = nil
        let old = peripheral; peripheral = nil
        invalidate()
        if let old { central?.cancelPeripheralConnection(old) }
        status = "Controles desconectados. O áudio do Mac permanece independente."
    }
    private func presetTitle(_ value: UInt8) -> String {
        return Int(value) < QCYProtocol.presets.count ? QCYProtocol.presets[Int(value)] : "Desconhecido"
    }
    private func batteryText(_ cell: RCSPBattery.Cell?) -> String {
        guard let cell else { return "não exposta" }
        return "\(cell.percentage)%" + (cell.charging ? " (carregando)" : "")
    }
    var report: String {
        "QCY Control 1.5.6\nCandidatos T13 ANC: \(candidates.count)\nControle BLE: \(status)\nProtocolo: \(rcspActive ? "Jieli/RCSP legado" : "QCY A001 / inspeção")\nFirmware BLE: \(firmware ?? "não confirmado")\nANC: \(noise?.title ?? "não confirmado")\nJogo: \(game.map { $0 ? "ligado" : "desligado" } ?? "não confirmado")\nEQ: \(preset.map { presetTitle($0) } ?? (rcspActive && rcspClient.canEQ ? "Perfil atual dos fones (curva não identificada)" : "não confirmado"))\nBateria RCSP: E \(batteryText(rcspClient.battery?.left)), D \(batteryText(rcspClient.battery?.right)), Estojo \(batteryText(rcspClient.battery?.caseBattery))\nToques RCSP: \(rcspClient.touches.count) gestos consultados\nErro: \(error ?? "nenhum")\n" + trace.joined(separator: "\n")
    }
}

@MainActor final class QCYControlManager: ObservableObject {
    @Published private(set) var status = "Conecte os controles para consultar as funções dos fones."
    @Published private(set) var candidates: [ControlCandidate] = []
    @Published private(set) var awaitingConnection = false
    @Published private(set) var gains: [Int]?
    @Published private(set) var battery: RCSPBattery?
    @Published private(set) var scanning = false
    @Published private(set) var connected = false
    @Published private(set) var firmware: String?
    @Published private(set) var noise: NoiseMode?
    @Published private(set) var game: Bool?
    @Published private(set) var preset: UInt8?
    @Published private(set) var pending: String?
    @Published private(set) var error: String?
    @Published private(set) var lastConfirmation: String?
    @Published private(set) var canNoise = false
    @Published private(set) var canGame = false
    @Published private(set) var canEQ = false
    @Published private(set) var canObserve = false
    @Published private(set) var rcsp = false
    @Published private(set) var touches: [RCSPTouch] = []
    @Published private(set) var canTouch = false
    @Published private(set) var observing = false
    private(set) var report = "QCY Control 1.5.6: controles ainda não consultados."
    var busy: Bool { pending != nil }
    private var engine: QCYControlEngine!
    init() {
        engine = QCYControlEngine { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.status = state.status; self.candidates = state.candidates
                self.awaitingConnection = state.awaitingConnection; self.gains = state.gains
                self.battery = state.battery
                self.scanning = state.scanning; self.connected = state.connected; self.firmware = state.firmware
                self.noise = state.noise; self.game = state.game; self.preset = state.preset
                self.pending = state.pending; self.error = state.error; self.lastConfirmation = state.lastConfirmation
                self.canNoise = state.canNoise; self.canGame = state.canGame; self.canEQ = state.canEQ
                self.canObserve = state.canObserve; self.observing = state.observing
                self.rcsp = state.rcsp; self.touches = state.touches; self.canTouch = state.canTouch
                self.report = state.report
            }
        }
    }
    func startScan(probe: Bool = true) {
        let engine = engine!
        engine.queue.async { engine.startScan(probe: probe) }
    }
    @Published private(set) var logMessage: String?
    func startAutomatic() { let engine = engine!; engine.queue.async { engine.startAutomatic() } }
    func systemConnectionArrived() { let engine = engine!; engine.queue.async { engine.systemConnectionArrived() } }
    func setGains(_ gains: [Int]) { let engine = engine!; engine.queue.async { engine.setGains(gains) } }
    func saveDiagnostic() {
        let panel = NSSavePanel()
        panel.title = "Salvar diagnóstico QCY Control"
        panel.nameFieldStringValue = "QCY-Control-Logs-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let engine = self.engine!
            engine.queue.async {
                let text = engine.report
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    Task { @MainActor in self.logMessage = "Diagnóstico salvo em \(url.path)" }
                } catch {
                    Task { @MainActor in self.logMessage = "Não foi possível salvar: \(error.localizedDescription)" }
                }
            }
        }
    }
    func connect(_ id: UUID) { let engine = engine!; engine.queue.async { engine.connect(id) } }
    func disconnect() { let engine = engine!; engine.queue.async { engine.disconnect() } }
    func setNoise(_ mode: NoiseMode) { let engine = engine!; engine.queue.async { engine.setNoise(mode) } }
    func setGame(_ enabled: Bool) { let engine = engine!; engine.queue.async { engine.setGame(enabled) } }
    func setPreset(_ value: UInt8) { let engine = engine!; engine.queue.async { engine.setPreset(value) } }
    func setTouch(_ id: Int, function: UInt8) { let engine = engine!; engine.queue.async { engine.setTouch(id, function: function) } }
    func refreshControls() { let engine = engine!; engine.queue.async { engine.refreshControls() } }
    func refreshBattery() { let engine = engine!; engine.queue.async { engine.refreshBattery() } }
    func observe() { let engine = engine!; engine.queue.async { engine.observe() } }
    func stopObservation() { let engine = engine!; engine.queue.async { engine.stopObservation() } }
}

extension QCYControlManager {
    // No central manager or peripheral is created by this regression check.
    func checkResponsiveness() async -> Bool {
        let engine = engine!
        let release = DispatchSemaphore(value: 0)
        let offMain: Bool = await withCheckedContinuation { continuation in
            engine.queue.async {
                continuation.resume(returning: !Thread.isMainThread)
                _ = release.wait(timeout: .now() + 3)
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        setNoise(.anc); setGame(true); setPreset(1); setTouch(258, function: 3); refreshControls(); observe(); stopObservation()
        try? await Task.sleep(for: .milliseconds(50))
        let responsive = ProcessInfo.processInfo.systemUptime - start < 1
        release.signal()
        return responsive && offMain
    }
}
