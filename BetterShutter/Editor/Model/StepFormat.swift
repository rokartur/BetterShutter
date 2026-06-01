import Foundation

/// How a numbered step badge renders its sequence value.
nonisolated enum StepFormat: String, CaseIterable, Sendable {
    case decimal      // 1, 2, 3
    case alphabetic   // A, B, C … Z, AA, AB
    case roman        // I, II, III, IV

    var presentableName: String {
        switch self {
        case .decimal: return "1, 2, 3"
        case .alphabetic: return "A, B, C"
        case .roman: return "I, II, III"
        }
    }

    /// The label for a 1-based sequence value. Values < 1 fall back to plain decimal.
    func string(for value: Int) -> String {
        switch self {
        case .decimal: return String(value)
        case .alphabetic: return Self.alpha(value)
        case .roman: return Self.roman(value)
        }
    }

    private static func alpha(_ value: Int) -> String {
        guard value >= 1 else { return String(value) }
        var n = value
        var result = ""
        while n > 0 {
            let rem = (n - 1) % 26
            result = String(UnicodeScalar(65 + rem)!) + result
            n = (n - 1) / 26
        }
        return result
    }

    private static func roman(_ value: Int) -> String {
        guard value >= 1, value < 4000 else { return String(value) }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var n = value
        var result = ""
        for (v, sym) in table {
            while n >= v { result += sym; n -= v }
        }
        return result
    }
}
