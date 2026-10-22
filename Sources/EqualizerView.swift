import SwiftUI

// Interaction/preset grid adapted from uxtigos/qcy-mac (MIT).
// See THIRD-PARTY-NOTICES.md. The HT-08 parametric wire format is NOT used:
// T13 ANC still receives ten integer gains through the validated RCSP FF path.
struct EqualizerView: View {
    @ObservedObject var controls: QCYControlManager
    @State private var draft = Array(repeating: 0, count: 10)
    @State private var original: [Int]?
    @State private var custom = UserDefaults.standard.array(forKey: "equalizer.customGains") as? [Int]
    @State private var selected = "Original"
    @State private var selectedBand = 4
    @State private var dragging: Int?
    @State private var dirty = false
    @State private var applying = false
    @State private var inspector = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let presets = ["Original", "Neutro", "Graves", "Vocal", "Agudos", "Personalizado"]
    private let frequencies = [31,62,125,250,500,1000,2000,4000,8000,16000]
    private var available: Bool { controls.rcsp && controls.canEQ && controls.gains?.count == 10 }
    private var editable: Bool { available && !controls.busy && !applying }
    private var valid: Bool { draft.count == 10 && draft.allSatisfy { (-6...6).contains($0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(presets, id: \.self) { name in
                    Button { choose(name) } label: {
                        Text(name).font(.system(size: 11, weight: selected == name ? .semibold : .regular))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(selected == name ? Color.white : Color.primary)
                            .background(selected == name ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).disabled(!editable)
                        .accessibilityAddTraits(selected == name ? .isSelected : [])
                }
            }
            T13EqualizerGraph(gains: draft, rangeDB: 6, selected: selected == "Personalizado" ? selectedBand : nil,
                              dragging: dragging != nil, reducedMotion: reduceMotion,
                              editable: editable && selected == "Personalizado",
                              changed: { index, gain in
                                  dragging = index; selectedBand = index
                                  draft[index] = gain; dirty = true
                              }, ended: { dragging = nil; rememberCustom(); apply() })
                .frame(height: 185).opacity(available ? 1 : 0.45)
            if selected == "Personalizado" {
                HStack {
                    Text("Arraste uma bolinha para ajustar.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { inspector.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.plain).help("Ajuste preciso por banda")
                        .accessibilityLabel("Mostrar ajuste preciso por banda")
                }
                if inspector {
                    HStack {
                        Picker("Frequência", selection: $selectedBand) {
                            ForEach(0..<10) { Text(label(frequencies[$0])).tag($0) }
                        }.labelsHidden().frame(width: 95)
                        Slider(value: Binding(get: { Double(draft[selectedBand]) }, set: {
                            draft[selectedBand] = Int($0.rounded()); dirty = true
                        }), in: -6...6, step: 1, onEditingChanged: { editing in
                            if !editing { rememberCustom(); apply() }
                        }).accessibilityLabel("Ganho da banda de \(frequencies[selectedBand]) hertz")
                        Text("\(draft[selectedBand] > 0 ? "+" : "")\(draft[selectedBand]) dB").font(.caption).monospacedDigit().frame(width: 45)
                    }.disabled(!editable)
                }
            }
            HStack {
                Menu("Perfis QCY") {
                    ForEach(Array(QCYProtocol.presets.enumerated()), id: \.offset) { index, name in
                        Button(name) { selected = "Personalizado"; draft = RCSPProtocol.eqCurves[index].map(Int.init); dirty = true; rememberCustom(); apply() }
                    }
                }.disabled(!editable)
                Spacer()
                Button("Redefinir") { selected = "Personalizado"; draft = Array(repeating: 0, count: 10); dirty = true; rememberCustom(); apply() }.disabled(!editable)
            }
            if applying || controls.busy {
                Label("Confirmando nos fones…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
            } else if dirty {
                Button("Aplicar ajuste") { apply() }.disabled(!editable || !valid)
            } else if available {
                Text(selected == "Original" ? "Original: curva lida no início desta sessão." : "A alteração é enviada ao selecionar um perfil ou soltar a bolinha.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Aguardando a conexão automática dos controles…").font(.caption).foregroundStyle(.secondary)
            }
            if let error = controls.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !valid && available {
                Text("A curva recebida excede a faixa de edição. Escolha um perfil para ajustar entre −6 e +6 dB.").font(.caption).foregroundStyle(.secondary)
            }
            Text("10 bandas fixas · −6 a +6 dB · ganhos gravados nos fones.")
                .font(.caption2).foregroundStyle(.secondary)
            DisclosureGroup("Sobre este equalizador") {
                Text("Interface adaptada do QCY MeloBuds, de Thiago Oliveira (MIT). No T13 ANC, editamos os ganhos de frequências fixas, em passos de 1 dB. Frequência e Q paramétricos do HT-08 não estão disponíveis. A curva desenhada interpola os ganhos; não é uma medição da resposta acústica. Original restaura a leitura inicial desta sessão, não um padrão de fábrica.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.font(.caption)
        }
        .onAppear { receive() }
        .onChange(of: controls.gains) { _, _ in if !dirty && !applying && dragging == nil { receive() } }
        .onChange(of: controls.busy) { _, busy in
            if !busy && applying {
                applying = false
                if controls.error == nil { receive() }
                else { dirty = true } // retain the user's draft for an explicit retry
            }
        }
        .onChange(of: controls.connected) { _, connected in if !connected { applying = false; dragging = nil } }
    }
    private func label(_ frequency: Int) -> String { frequency >= 1000 ? "\(frequency / 1000) kHz" : "\(frequency) Hz" }
    private func receive() {
        guard let gains = controls.gains, gains.count == 10 else { return }
        if original == nil { original = gains }
        draft = gains; dirty = false
    }
    private func choose(_ name: String) {
        selected = name
        if name == "Original", let original { draft = original }
        else if name == "Personalizado" {
            if let custom, custom.count == 10, custom.allSatisfy({ (-6...6).contains($0) }) { draft = custom }
            inspector = true
        } else {
            draft = frequencies.map { f in
                let gain: Double
                switch name {
                case "Graves": gain = f < 90 ? 6 : f < 180 ? 4.5 : f < 350 ? 2.5 : f < 700 ? 1 : 0
                case "Vocal": gain = f < 200 ? -2 : f < 700 ? 0.5 : f < 1500 ? 2 : f < 4500 ? 3 : f < 9000 ? 1.5 : 0
                case "Agudos": gain = f < 1500 ? 0 : f < 3500 ? 1.5 : f < 7000 ? 3.5 : 5
                default: gain = 0
                }
                return Int(gain.rounded())
            }
        }
        dirty = true; apply()
    }
    private func rememberCustom() {
        guard valid else { return }
        custom = draft; UserDefaults.standard.set(draft, forKey: "equalizer.customGains")
    }
    private func apply() {
        guard available, !controls.busy, !applying, valid else { return }
        guard draft != controls.gains else { dirty = false; return }
        applying = true; dirty = false; controls.setGains(draft)
    }
}
