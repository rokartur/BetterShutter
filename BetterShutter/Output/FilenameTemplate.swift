import Foundation

/// Renders a capture filename from a user template.
///
/// Tokens: `%y` year, `%n` month, `%d` day, `%w` weekday name, `%H` hour, `%M` minute,
/// `%S` second, `%r` random 4-character suffix, plus the legacy `{date}` → yyyy-MM-dd,
/// `{time}` → HH.mm.ss, `{datetime}` → both, `{n}` → capture counter, `{mode}` → Region/Window/Screen.
/// The result is sanitized of path-illegal characters and always carries the format extension.
nonisolated enum FilenameTemplate {
    /// The out-of-the-box template: "capture screen Friday 04 07 2026 at 19.05.32 8FA3".
    static let defaultTemplate = "capture screen %w %d %n %y at %H.%M.%S %r"

    static func render(
        _ template: String,
        mode: CaptureMode,
        format: ImageFileFormat,
        counter: Int,
        date: Date = Date()
    ) -> String {
        render(template, modeTag: mode.fileTag, fileExtension: format.fileExtension, counter: counter, date: date)
    }

    /// Extension-agnostic variant so recordings (mp4/gif) share the same naming as screenshots.
    static func render(
        _ template: String,
        modeTag: String,
        fileExtension: String,
        counter: Int,
        date: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var name = template.isEmpty ? defaultTemplate : template

        // Percent tokens — each is a single DateFormatter pattern, resolved only when present.
        let calendarTokens: [(token: String, pattern: String)] = [
            ("%H", "HH"), ("%M", "mm"), ("%S", "ss"),
            ("%y", "yyyy"), ("%n", "MM"), ("%d", "dd"), ("%w", "EEEE"),
        ]
        for (token, pattern) in calendarTokens where name.contains(token) {
            formatter.dateFormat = pattern
            name = name.replacingOccurrences(of: token, with: formatter.string(from: date))
        }
        if name.contains("%r") {
            name = name.replacingOccurrences(of: "%r", with: String(UUID().uuidString.prefix(4)))
        }

        // Legacy brace tokens.
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: date)
        formatter.dateFormat = "HH.mm.ss"
        let timeString = formatter.string(from: date)
        name = name.replacingOccurrences(of: "{datetime}", with: "\(dateString) at \(timeString)")
        name = name.replacingOccurrences(of: "{date}", with: dateString)
        name = name.replacingOccurrences(of: "{time}", with: timeString)
        name = name.replacingOccurrences(of: "{n}", with: String(counter))
        name = name.replacingOccurrences(of: "{mode}", with: modeTag)

        name = sanitize(name)
        if name.isEmpty { name = "Screenshot" }
        return "\(name).\(fileExtension)"
    }

    private static func sanitize(_ s: String) -> String {
        // Disallow path separators and characters that break Finder / cross-platform names.
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = s.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
