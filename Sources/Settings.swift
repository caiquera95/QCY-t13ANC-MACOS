import AppKit
import SwiftUI

@MainActor final class Settings: ObservableObject {
    @Published var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "Sistema" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance"); apply() }
    }
    func apply() {
        NSApp.appearance = appearance == "Claro" ? NSAppearance(named: .aqua) : appearance == "Escuro" ? NSAppearance(named: .darkAqua) : nil
    }
    func openBluetooth() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) }
}
