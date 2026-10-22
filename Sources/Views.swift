import SwiftUI
import AppKit

struct Vibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .popover; view.blendingMode = .behindWindow; view.state = .active; return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
// SwiftUI's HostingScrollView ignores .scrollIndicators(.hidden) on Sonoma
// when system scrollbars are configured as always visible.
@MainActor enum QCYScrollIndicators {
    static func hide(in view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.hasVerticalScroller = false
            scroll.verticalScroller?.isHidden = true
        }
        for child in view.subviews { hide(in: child) }
    }
}

struct PanelView: View {
    @ObservedObject var bluetooth: BluetoothManager
    @ObservedObject var audio: AudioManager
    @ObservedObject var settings: Settings
    @ObservedObject var controls: QCYControlManager
    @ObservedObject var softwareEQ: SoftwareEQManager
    @State private var tab = 0
    @State private var diagnostics = false
    init(bluetooth: BluetoothManager, audio: AudioManager, settings: Settings, controls: QCYControlManager, softwareEQ: SoftwareEQManager, initialTab: Int = 0) {
        self.bluetooth = bluetooth; self.audio = audio; self.settings = settings; self.controls = controls; self.softwareEQ = softwareEQ
        _tab = State(initialValue: initialTab)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "earbuds").font(.system(size: 28, weight: .medium))
                        .frame(width: 46, height: 46)
                        .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bluetooth.state.name).font(.system(size: 15, weight: .bold))
                        HStack(spacing: 5) {
                            Circle().fill(bluetooth.state.connected ? Color.green : Color.yellow).frame(width: 7, height: 7)
                            Text(bluetooth.state.connected ? "Conectado" : "Procurando fones…")
                            if controls.battery == nil, let battery = bluetooth.state.battery {
                                Text("· \(battery)%").accessibilityLabel("Bateria geral informada pelo macOS: \(battery) por cento")
                            }
                        }.font(.caption)
                    }
                    Spacer(minLength: 0)
                    Button { tab = 2 } label: { Image(systemName: "gearshape").font(.system(size: 15)) }
                        .buttonStyle(.plain).help("Ajustes").accessibilityLabel("Abrir ajustes")
                }.foregroundStyle(.primary)
                if controls.connected, let battery = controls.battery {
                    HStack(spacing: 8) {
                        batteryCell("Esquerdo", battery.left)
                        batteryCell("Direito", battery.right)
                        batteryCell("Estojo", battery.caseBattery)
                    }
                }
                HStack(spacing: 3) {
                    tabButton("Controle", index: 0)
                    tabButton("Som", index: 1)
                    tabButton("Ajustes", index: 2)
                }.padding(3).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if tab == 0 {
                        volumeSection
                        ControlConnectionView(controls: controls)
                        section("CONTROLE DE RUÍDO") {
                            HStack(spacing: 8) { mode(.anc, "waveform.path"); mode(.normal, "ear"); mode(.transparency, "waveform") }
                            Text(controls.canNoise ? (controls.noise == nil ? "Modo atual não identificado. Você pode selecionar um dos modos acima." : "Estado consultado diretamente nos fones.") : "Aguardando uma resposta de ANC compatível dos fones.").font(.caption).foregroundStyle(.secondary)
                        }
                        section("ACESSO RÁPIDO") {
                            Toggle("Modo jogo", isOn: Binding(get: { controls.game ?? false }, set: { controls.setGame($0) })).disabled(!controls.canGame || controls.busy)
                            Text(controls.canGame ? "Modo de baixa latência interno dos fones." : "Aguardando confirmação de suporte pelos fones.").font(.caption).foregroundStyle(.secondary)
                        }
                        if controls.rcsp {
                            section("CONTROLE DE TOQUES") {
                                if controls.touches.isEmpty { Text("Aguardando o mapeamento de toques informado pelos fones.").font(.caption).foregroundStyle(.secondary) }
                                ForEach(controls.touches) { touch in
                                    Picker(touch.title, selection: Binding(get: { touch.function }, set: { controls.setTouch(touch.id, function: $0) })) {
                                        if !RCSPTouch.functions.contains(where: { $0.0 == touch.function }) { Text("Função \(touch.function)").tag(touch.function) }
                                        ForEach(RCSPTouch.functions, id: \.0) { function, title in Text(title).tag(function) }
                                    }.disabled(!controls.canTouch || controls.busy)
                                }
                                Text("São exibidos apenas os gestos retornados pelos fones. Cada alteração é verificada por nova consulta.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else if tab == 1 {
                        section("EQUALIZAÇÃO DO MAC") {
                            SoftwareEqualizerView(audio: audio, software: softwareEQ)
                        }
                        section("EQUALIZADOR DOS FONES") {
                            EqualizerView(controls: controls)
                        }
                        volumeSection
                        section("SAÍDA DE ÁUDIO") {
                            Picker("Dispositivo", selection: Binding(get: { audio.selected }, set: { audio.select($0) })) {
                                if audio.outputs.isEmpty { Text("Nenhuma saída").tag(UInt32(0)) }
                                ForEach(audio.outputs) { Text($0.name).tag($0.id) }
                            }.labelsHidden()
                            Text("A seleção altera a saída padrão do macOS.").font(.caption).foregroundStyle(.secondary)
                        }
                        ControlConnectionView(controls: controls)
                    } else {
                        section("PREFERÊNCIAS") {
                            Picker("Aparência", selection: $settings.appearance) { ForEach(["Sistema", "Claro", "Escuro"], id: \.self) { Text($0) } }
                            Text("Para iniciar com o Mac, adicione este aplicativo em Ajustes do Sistema → Geral → Itens de Início.").font(.caption).foregroundStyle(.secondary)
                        }
                        section("DISPOSITIVO") {
                            LabeledContent("Modelo", value: bluetooth.state.name)
                            LabeledContent("Firmware", value: bluetooth.state.firmware ?? "Não informado")
                            LabeledContent("Aplicativo", value: "QCY Control 1.5.6")
                            Text("Aplicativo independente, sem vínculo com a QCY.").font(.caption).foregroundStyle(.secondary)
                        }
                        section("DIAGNÓSTICOS") {
                            Button("Atualizar Bluetooth") { bluetooth.refresh() }
                            Button("Salvar diagnóstico…") { controls.saveDiagnostic() }
                            Button("Copiar diagnóstico dos controles") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(controls.report, forType: .string)
                            }
                            DisclosureGroup("Estado técnico", isExpanded: $diagnostics) {
                                Text(Diagnostics.report(bluetooth: bluetooth, audio: audio)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Button("Encerrar QCY Control", role: .destructive) { NSApp.terminate(nil) }.frame(maxWidth: .infinity)
                    }
                    if let error = audio.error { Text(error).font(.caption).foregroundStyle(.red) }
                }.padding(.bottom, 4)
            }.scrollIndicators(.hidden)
            HStack {
                Text("Áudio do Mac. Controle ao seu alcance.").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "lock.shield").foregroundStyle(.tertiary).help("Sem servidor, conta ou telemetria")
            }
        }.padding(14).frame(width: 390, height: 600)
            .background(Vibrancy())
            .onAppear { bluetooth.refresh(); controls.startAutomatic() }
            .onChange(of: bluetooth.state.connected) { _, connected in
                if connected { controls.startAutomatic() }
            }
    }
    private var volumeSection: some View {
        section("VOLUME DO MAC") {
            HStack { Image(systemName: "speaker.fill"); Slider(value: Binding(get: { audio.volume }, set: { audio.setVolume($0) }), in: 0...1).disabled(!audio.writable).accessibilityLabel("Volume da saída do macOS"); Image(systemName: "speaker.wave.3.fill"); Text(audio.writable ? "\(Int(audio.volume * 100))%" : "—").monospacedDigit().frame(width: 38) }
            Text(audio.outputName).font(.caption).lineLimit(2)
            Text(audio.writable ? "Volume da saída do macOS; pode ser sincronizado pelos fones." : "Esta saída não expõe um controle de volume compatível.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func tabButton(_ title: String, index: Int) -> some View {
        Button { tab = index } label: {
            Text(title).font(.system(size: 12, weight: tab == index ? .semibold : .medium))
                .frame(maxWidth: .infinity, minHeight: 27)
                .foregroundStyle(.primary)
                .background(tab == index ? Color.primary.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(tab == index ? .isSelected : [])
    }
    private func batteryCell(_ title: String, _ cell: RCSPBattery.Cell?) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                if cell?.charging == true { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                Text(cell.map { "\($0.percentage)%" } ?? "—").monospacedDigit()
            }.font(.system(size: 12, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Bateria \(title): \(cell.map { "\($0.percentage) por cento" } ?? "não informada")\(cell?.charging == true ? ", carregando" : "")")
    }
    private func mode(_ mode: NoiseMode, _ symbol: String) -> some View {
        Button { controls.setNoise(mode) } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 22, weight: .light))
                Text(mode.title).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 65)
            .foregroundStyle(!controls.canNoise ? Color.secondary : controls.noise == mode ? Color.accentColor : Color.primary)
            .background(controls.noise == mode ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(controls.noise == mode ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1))
        }.buttonStyle(.plain).disabled(!controls.canNoise || controls.busy)
            .accessibilityAddTraits(controls.noise == mode ? .isSelected : [])
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
            content()
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
