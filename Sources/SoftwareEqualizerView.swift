import SwiftUI

// Software path is opt-in and separate from the T13 hardware EQ above.
struct SoftwareEqualizerView: View {
    @ObservedObject var audio: AudioManager
    @ObservedObject var software: SoftwareEQManager
    @State private var draft: [Int]
    @State private var selectedBand = 4
    @State private var selectedProfile = "Personalizado"
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    init(audio: AudioManager, software: SoftwareEQManager) {
        self.audio = audio; self.software = software
        _draft = State(initialValue: software.gains)
    }
    private var canRoute: Bool { QCYProtocol.targetName(audio.outputName) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Processar áudio do Mac", isOn: Binding(get: { software.enabled }, set: { value in
                if value { software.enable(output: audio.selected, name: audio.outputName) }
                else { software.disable() }
            })).disabled(software.busy || (!software.enabled && !canRoute))
            Text(software.enabled ? "Áudio do Mac passa pelo equalizador e sai nos QCY T13 ANC." : "Selecione QCY-T13 ANC como saída e ative para ouvir os ajustes abaixo.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Ganho geral")
                Slider(value: Binding(get: { Double(software.masterDB) }, set: { software.masterDB = Int($0) }),
                       in: 0...6, step: 1, onEditingChanged: { editing in if !editing { software.apply() } })
                    .accessibilityLabel("Ganho adicional do áudio do Mac")
                Text("+\(software.masterDB) dB").monospacedDigit().frame(width: 48, alignment: .trailing)
            }.font(.caption).disabled(software.busy)
            HStack(spacing: 5) {
                profile("Neutro", gains: [0,0,0,0,0,0,0,0,0,0])
                profile("Graves", gains: [8,7,5,2,0,-1,-1,0,0,0])
                profile("Voz", gains: [-2,-2,-1,1,3,4,3,1,0,0])
                profile("Brilho", gains: [0,0,0,0,0,1,3,5,6,6])
                Button("Personalizado") { selectedProfile = "Personalizado" }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            T13EqualizerGraph(gains: draft, rangeDB: 12,
                              selected: selectedProfile == "Personalizado" ? selectedBand : nil,
                              dragging: dragging, reducedMotion: reduceMotion,
                              editable: selectedProfile == "Personalizado" && !software.busy,
                              changed: { index, gain in
                                  selectedBand = index; dragging = true; draft[index] = gain
                              }, ended: { dragging = false; applyDraft() })
                .frame(height: 185)
            HStack {
                Picker("Banda", selection: $selectedBand) {
                    ForEach(0..<10, id: \.self) { index in Text("\(frequencies[index]) Hz").tag(index) }
                }.labelsHidden().frame(width: 95)
                Slider(value: Binding(get: { Double(draft[selectedBand]) }, set: {
                    draft[selectedBand] = Int($0.rounded()); selectedProfile = "Personalizado"
                }), in: -12...12, step: 1, onEditingChanged: { editing in if !editing { applyDraft() } })
                    .accessibilityLabel("Banda \(frequencies[selectedBand]) hertz do áudio do Mac")
                Text("\(draft[selectedBand] > 0 ? "+" : "")\(draft[selectedBand]) dB")
                    .monospacedDigit().frame(width: 46, alignment: .trailing)
            }.font(.caption).disabled(software.busy)
            if software.busy { Text("Preparando a rota de áudio…").font(.caption).foregroundStyle(.secondary) }
            if let error = software.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("10 bandas de −12 a +12 dB · ganho geral até +6 dB · limitador de picos. O processamento funciona apenas enquanto estiver ativado; a primeira ativação pede permissão de áudio do sistema.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: software.gains) { _, gains in if !dragging { draft = gains } }
    }
    private func profile(_ title: String, gains: [Int]) -> some View {
        Button(title) { selectedProfile = title; draft = gains; applyDraft() }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(software.busy)
    }
    private func applyDraft() {
        guard draft.count == 10, draft.allSatisfy({ (-12...12).contains($0) }) else { return }
        software.gains = draft
        software.apply()
    }
}
