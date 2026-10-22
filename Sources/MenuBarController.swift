import AppKit
import SwiftUI
import Combine
@MainActor private final class QCYHostingController: NSHostingController<PanelView> {
    override func viewDidLayout() {
        super.viewDidLayout()
        QCYScrollIndicators.hide(in: view)
    }
}

@MainActor final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let disconnectedIcon = NSImage(systemSymbolName: "earbuds", accessibilityDescription: "QCY Control")
    private lazy var connectedIcon: NSImage? = {
        guard let symbol = disconnectedIcon else { return nil }
        let palette = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
        guard let icon = symbol.withSymbolConfiguration(palette) else { return nil }
        icon.isTemplate = false
        return icon
    }()
    private var connectionObservation: AnyCancellable?
    init(bluetooth: BluetoothManager, audio: AudioManager, settings: Settings, controls: QCYControlManager, softwareEQ: SoftwareEQManager) {
        super.init()
        if let button = item.button {
            disconnectedIcon?.isTemplate = true
            button.image = disconnectedIcon
            button.toolTip = "QCY Control — clique para abrir"
            button.target = self; button.action = #selector(toggle)
        }
        updateIcon(connected: bluetooth.state.connected)
        connectionObservation = bluetooth.$state.map(\.connected).removeDuplicates().sink { [weak self] connected in
            self?.updateIcon(connected: connected)
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 390, height: 600)
        popover.contentViewController = QCYHostingController(rootView: PanelView(bluetooth: bluetooth, audio: audio, settings: settings, controls: controls, softwareEQ: softwareEQ))
    }
    private func updateIcon(connected: Bool) {
        // Keep the SF Symbol's native proportions and embedded green palette.
        item.button?.contentTintColor = nil
        item.button?.image = connected ? connectedIcon : disconnectedIcon
        item.button?.toolTip = connected ? "QCY Control — fones conectados" : "QCY Control — fones desconectados"
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); QCYScrollIndicators.hide(in: popover.contentViewController!.view); NSApp.activate(ignoringOtherApps: true) }
    }
}
