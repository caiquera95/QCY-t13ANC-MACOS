import Foundation

struct HeadphoneState {
    var name = "QCY T13 ANC"
    var found = false
    var connected = false
    var battery: Int?
    var firmware: String?
    var note = "Consultando Bluetooth…"
    var updated: Date?
}

struct BatteryParser {
    static func percentage(_ value: Any?) -> Int? {
        guard let value else { return nil }
        let string = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
        guard let number = Int(string), (0...100).contains(number) else { return nil }
        return number
    }
    static func matches(_ name: String) -> Bool {
        let name = name.uppercased().filter { $0.isLetter || $0.isNumber }
        return name.contains("QCY") && name.contains("T13") && name.contains("ANC")
    }
}
