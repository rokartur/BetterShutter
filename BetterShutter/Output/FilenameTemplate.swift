import Foundation

/// Renders a screenshot filename from a user template.
///
/// Tokens: `{date}` → yyyy-MM-dd, `{time}` → HH.mm.ss, `{datetime}` → both,
/// `{n}` → capture counter, `{mode}` → Region/Window/Screen.
/// The result is sanitized of path-illegal characters and always carries the format extension.
nonisolated enum FilenameTemplate {
    static func render(
        _ template: String,
        mode: CaptureMode,
        format: ImageFileFormat,
        counter: Int,
        date: Date = Date()
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH.mm.ss"

        let dateString = dateFormatter.string(from: date)
        let timeString = timeFormatter.string(from: date)

        var name = template.isEmpty ? "Screenshot {datetime}" : template
        name = name.replacingOccurrences(of: "{datetime}", with: "\(dateString) at \(timeString)")
        name = name.replacingOccurrences(of: "{date}", with: dateString)
        name = name.replacingOccurrences(of: "{time}", with: timeString)
        name = name.replacingOccurrences(of: "{n}", with: String(counter))
        name = name.replacingOccurrences(of: "{mode}", with: mode.fileTag)

        name = sanitize(name)
        if name.isEmpty { name = "Screenshot" }
        return "\(name).\(format.fileExtension)"
    }

    private static func sanitize(_ s: String) -> String {
        // Disallow path separators and characters that break Finder / cross-platform names.
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = s.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
