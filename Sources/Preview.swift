import AppKit
import SwiftUI

@MainActor enum Preview {
    // An offscreen native window allows visual QA without recording the user's screen.
    static var window: NSWindow?
    static func capture(bluetooth: BluetoothManager, audio: AudioManager, settings: Settings, controls: QCYControlManager, softwareEQ: SoftwareEQManager, path: String) {
        let tab = CommandLine.arguments.contains("--sound") ? 1 : CommandLine.arguments.contains("--settings") ? 2 : 0
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        let host = NSHostingView(rootView: PanelView(bluetooth: bluetooth, audio: audio, settings: settings, controls: controls, softwareEQ: softwareEQ, initialTab: tab))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            host.layoutSubtreeIfNeeded()
            QCYScrollIndicators.hide(in: host)
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do { try png.write(to: URL(fileURLWithPath: path)); print("Interface renderizada: \(path)"); exit(0) }
            catch { print("Falha de renderização: \(error)"); exit(1) }
        }
    }
}
