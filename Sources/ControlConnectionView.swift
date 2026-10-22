import SwiftUI
import AppKit

struct ControlConnectionView: View {
    @ObservedObject var controls: QCYControlManager
    @State private var details = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CONTROLES DOS FONES").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                Spacer()
                if controls.scanning || controls.busy || controls.observing { ProgressView().controlSize(.small) }
            }
            Text(controls.connected ? "Controles conectados. As funções são consultadas nos fones." : controls.status)
                .font(.caption).foregroundStyle(.secondary)
            if let error = controls.error { Text(error).font(.caption).foregroundStyle(.red) }
            DisclosureGroup("Opções e diagnóstico", isExpanded: $details) {
            VStack(alignment: .leading, spacing: 8) {
            if controls.connected {
                if controls.rcsp { Button("Atualizar funções dos fones") { controls.refreshControls() }.disabled(controls.busy) }
                Button("Desconectar controles") { controls.disconnect() }.disabled(controls.busy)
            } else if controls.awaitingConnection {
                Text("Não é necessário clicar em Conectar. Retire os fones da caixa e aguarde.").font(.caption).foregroundStyle(.secondary)
                Button("Pausar conexão automática") { controls.disconnect() }
            } else {
                Button(controls.scanning ? "Parar busca" : "Reconectar controles automaticamente") {
                    if controls.scanning { controls.disconnect() } else { controls.startScan() }
                }
                ForEach(controls.candidates) { candidate in
                    Button { controls.connect(candidate.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name)
                                Text(candidate.source).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(candidate.unavailable ? "Indisponível" : "Conectar").foregroundStyle(.tint)
                        }
                    }.disabled(candidate.unavailable)
                }
            }
            if controls.canObserve {
                Button(controls.observing ? "Parar observação" : "Observar notificações por 15 segundos") {
                    if controls.observing { controls.stopObservation() } else { controls.observe() }
                }
                Text("Durante a observação, você pode trocar o modo pelo toque dos fones. O app apenas recebe os dados enviados por eles.").font(.caption).foregroundStyle(.secondary)
            }
            if let pending = controls.pending { Text(pending).font(.caption) }
            if let confirmation = controls.lastConfirmation { Label(confirmation, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
            Button("Salvar diagnóstico…") { controls.saveDiagnostic() }.font(.caption)
            if let message = controls.logMessage { Text(message).font(.caption).textSelection(.enabled) }
            Button("Copiar diagnóstico") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(controls.report, forType: .string)
            }.font(.caption)
            }
            }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}
