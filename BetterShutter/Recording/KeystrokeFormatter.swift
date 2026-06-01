import AppKit

/// Turns a key event into a compact on-screen label like "⌘⇧A", "⎋", or "␣". Pure so it can be
/// unit-tested without a live event stream.
nonisolated enum KeystrokeFormatter {

    /// Special keys that read better as a symbol than their raw character.
    private static let specialByKeyCode: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
    ]

    static func display(modifiers: NSEvent.ModifierFlags, keyCode: UInt16, characters: String?) -> String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }

        let body: String
        if let special = specialByKeyCode[keyCode] {
            body = special
        } else if let chars = characters, !chars.isEmpty,
                  chars.first.map({ !$0.isWhitespace && !$0.isNewline }) ?? false {
            body = chars.uppercased()
        } else {
            body = ""
        }
        return prefix + body
    }
}
