import AppKit

/// Pure helpers for the editor's saved color palette: a most-recently-used list of hex colors.
nonisolated enum ColorPalette {
    /// Prepend `hex` to `list` (case-insensitive dedup), capped to `max` entries.
    static func add(_ hex: String, to list: [String], max: Int = 12) -> [String] {
        let key = hex.uppercased()
        var result = list.filter { $0.uppercased() != key }
        result.insert(key, at: 0)
        if result.count > max { result.removeLast(result.count - max) }
        return result
    }
}

extension NSColor {
    /// "#RRGGBB" in sRGB (drops alpha). Nil for colors that can't be brought into sRGB.
    var hexString: String? {
        guard let s = usingColorSpace(.sRGB) else { return nil }
        let r = Int((s.redComponent * 255).rounded())
        let g = Int((s.greenComponent * 255).rounded())
        let b = Int((s.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Parse "#RRGGBB" / "RRGGBB". Nil if malformed.
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
