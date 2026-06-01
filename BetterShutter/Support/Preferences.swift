import Foundation

/// What happens immediately after a capture succeeds.
nonisolated enum AfterCaptureAction: String, CaseIterable, Sendable {
    case both       // copy to pasteboard AND show the float preview
    case preview    // show the float preview only
    case copy       // copy to pasteboard only

    var copies: Bool { self == .both || self == .copy }
    var previews: Bool { self == .both || self == .preview }

    var presentableName: String {
        switch self {
        case .both: return "Copy & Show Preview"
        case .preview: return "Show Preview"
        case .copy: return "Copy to Clipboard"
        }
    }
}

/// Output image format.
nonisolated enum ImageFileFormat: String, CaseIterable, Sendable {
    case png
    case jpeg

    var fileExtension: String { self == .png ? "png" : "jpg" }
    var presentableName: String { self == .png ? "PNG" : "JPEG" }
}

/// Thread-safe app preferences backed by `UserDefaults`. Accessor-only (no isolation) so the
/// capture actor and main-actor UI can both read it. Hotkeys persist themselves via BetterShortcuts.
nonisolated enum Preferences {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let saveDirectory = "saveDirectoryPath"
        static let format = "imageFormat"
        static let jpegQuality = "jpegQuality"
        static let filenameTemplate = "filenameTemplate"
        static let afterCapture = "afterCaptureAction"
        static let magnifier = "magnifierEnabled"
        static let captureSound = "captureSoundEnabled"
        static let captureCounter = "captureCounter"
        static let recordSystemAudio = "recordSystemAudio"
        static let downscaleRetina = "downscaleRetina"
        static let highlightClicks = "highlightClicks"
    }

    /// Halve Retina (scale > 1) captures to 1× on output for smaller files.
    static var downscaleRetina: Bool {
        get { defaults.object(forKey: Key.downscaleRetina) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.downscaleRetina) }
    }

    /// Show an animated ring at each mouse click during recordings.
    static var highlightClicks: Bool {
        get { defaults.object(forKey: Key.highlightClicks) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.highlightClicks) }
    }

    static var recordSystemAudio: Bool {
        get { defaults.object(forKey: Key.recordSystemAudio) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.recordSystemAudio) }
    }

    /// Directory screenshots are saved to. Defaults to the Desktop.
    static var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: Key.saveDirectory), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { defaults.set(newValue.path, forKey: Key.saveDirectory) }
    }

    static var format: ImageFileFormat {
        get { ImageFileFormat(rawValue: defaults.string(forKey: Key.format) ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: Key.format) }
    }

    static var jpegQuality: Double {
        get { defaults.object(forKey: Key.jpegQuality) as? Double ?? 0.9 }
        set { defaults.set(newValue, forKey: Key.jpegQuality) }
    }

    static var filenameTemplate: String {
        get { defaults.string(forKey: Key.filenameTemplate) ?? "Screenshot {date} at {time}" }
        set { defaults.set(newValue, forKey: Key.filenameTemplate) }
    }

    static var afterCaptureAction: AfterCaptureAction {
        get { AfterCaptureAction(rawValue: defaults.string(forKey: Key.afterCapture) ?? "") ?? .both }
        set { defaults.set(newValue.rawValue, forKey: Key.afterCapture) }
    }

    static var magnifierEnabled: Bool {
        get { defaults.object(forKey: Key.magnifier) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.magnifier) }
    }

    static var captureSoundEnabled: Bool {
        get { defaults.object(forKey: Key.captureSound) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.captureSound) }
    }

    /// Monotonic counter for the `{n}` filename token.
    static func nextCaptureCounter() -> Int {
        let next = defaults.integer(forKey: Key.captureCounter) + 1
        defaults.set(next, forKey: Key.captureCounter)
        return next
    }
}
