import CoreGraphics
import Foundation

/// A persisted region selection (global bottom-left rect + the display it was on), for "Capture
/// Previous Area" across launches.
nonisolated struct StoredRegion: Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var display: UInt32

    init(rect: CGRect, displayID: CGDirectDisplayID) {
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
        display = displayID
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var displayID: CGDirectDisplayID { display }
}

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

/// How far back the Capture History bar shows past captures. Filters the saved-files view by
/// modification date — it never deletes the user's files.
nonisolated enum CaptureHistoryRetention: String, CaseIterable, Sendable {
    case day1
    case day3
    case day7
    case day14
    case day30
    case month3
    case unlimited

    /// Cutoff age in seconds; `nil` means keep everything.
    var maxAge: TimeInterval? {
        let day: TimeInterval = 86_400
        switch self {
        case .day1: return day
        case .day3: return day * 3
        case .day7: return day * 7
        case .day14: return day * 14
        case .day30: return day * 30
        case .month3: return day * 90
        case .unlimited: return nil
        }
    }

    var presentableName: String {
        switch self {
        case .day1: return "1 day"
        case .day3: return "3 days"
        case .day7: return "7 days"
        case .day14: return "14 days"
        case .day30: return "30 days"
        case .month3: return "3 months"
        case .unlimited: return "Unlimited"
        }
    }
}

/// Output image format.
nonisolated enum ImageFileFormat: String, CaseIterable, Sendable {
    case png
    case jpeg
    case heic
    case webp

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .webp: return "webp"
        }
    }

    var presentableName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .webp: return "WebP"
        }
    }

    /// PNG is lossless; JPEG/HEIC/WebP honor the quality slider.
    var isLossy: Bool { self != .png }
}

/// Thread-safe app preferences backed by `UserDefaults`. Accessor-only (no isolation) so the
/// capture actor and main-actor UI can both read it. Hotkeys persist themselves via BetterShortcuts.
nonisolated enum Preferences {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let saveDirectory = "saveDirectoryPath"
        static let saveToDisk = "saveScreenshotsToDisk"
        static let ocrHistory = "ocrHistoryEnabled"
        static let format = "imageFormat"
        static let jpegQuality = "jpegQuality"
        static let filenameTemplate = "filenameTemplate"
        static let afterCapture = "afterCaptureAction"
        static let magnifier = "magnifierEnabled"
        static let captureSound = "captureSoundEnabled"
        static let captureCounter = "captureCounter"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let showWebcam = "showWebcam"
        static let showKeystrokes = "showKeystrokes"
        static let downscaleRetina = "downscaleRetina"
        static let highlightClicks = "highlightClicks"
        static let showCursorInRecording = "showCursorInRecording"
        static let includeWindowShadow = "includeWindowShadow"
        static let includeWindowBorder = "includeWindowBorder"
        static let hasOnboarded = "hasOnboarded"
        static let recordingFPS = "recordingFPS"
        static let recordingInProgressPath = "recordingInProgressPath"
        static let beautifyPresets = "beautifyPresets"
        static let lastRegion = "lastRegion"
        static let stepFormat = "stepFormat"
        static let stepStart = "stepStart"
        static let recentColors = "recentColors"
        static let historyRetention = "captureHistoryRetention"
        static let captureDelay = "captureDelaySeconds"
        static let hideDesktopIcons = "hideDesktopIcons"
        static let focusShortcutStart = "focusShortcutStart"
        static let focusShortcutStop = "focusShortcutStop"
    }

    /// Name of a Shortcut to run when recording starts / stops (e.g. to turn a Focus on/off). macOS
    /// has no public Focus API, so this is the sanctioned workaround. Empty = disabled.
    static var focusShortcutStart: String {
        get { defaults.string(forKey: Key.focusShortcutStart) ?? "" }
        set { defaults.set(newValue, forKey: Key.focusShortcutStart) }
    }
    static var focusShortcutStop: String {
        get { defaults.string(forKey: Key.focusShortcutStop) ?? "" }
        set { defaults.set(newValue, forKey: Key.focusShortcutStop) }
    }

    /// Hide desktop icons during captures and recordings (seamless wallpaper cover, no Finder relaunch).
    static var hideDesktopIcons: Bool {
        get { defaults.bool(forKey: Key.hideDesktopIcons) }
        set { defaults.set(newValue, forKey: Key.hideDesktopIcons) }
    }

    /// Self-timer delay (seconds) before a capture fires; 0 = off. Lets the user arrange the screen
    /// (open menus, hover tooltips) first. Allowed values: 0 / 3 / 5 / 10.
    static var captureDelaySeconds: Int {
        get { defaults.integer(forKey: Key.captureDelay) }
        set { defaults.set(newValue, forKey: Key.captureDelay) }
    }

    /// How far back the Capture History bar reaches. Defaults to 30 days.
    static var captureHistoryRetention: CaptureHistoryRetention {
        get { CaptureHistoryRetention(rawValue: defaults.string(forKey: Key.historyRetention) ?? "") ?? .day30 }
        set { defaults.set(newValue.rawValue, forKey: Key.historyRetention) }
    }

    /// Recently used / saved editor colors as "#RRGGBB" hex, newest first.
    static var recentColors: [String] {
        get { defaults.stringArray(forKey: Key.recentColors) ?? [] }
        set { defaults.set(newValue, forKey: Key.recentColors) }
    }

    static func addRecentColor(_ hex: String) {
        recentColors = ColorPalette.add(hex, to: recentColors)
    }

    /// Numbering format for new step badges.
    static var stepFormat: StepFormat {
        get { StepFormat(rawValue: defaults.string(forKey: Key.stepFormat) ?? "") ?? .decimal }
        set { defaults.set(newValue.rawValue, forKey: Key.stepFormat) }
    }

    /// First label value for step badges (1 unless the user changed it).
    static var stepStart: Int {
        get { let v = defaults.integer(forKey: Key.stepStart); return v == 0 ? 1 : v }
        set { defaults.set(newValue, forKey: Key.stepStart) }
    }

    /// The last region selection (global rect + display), persisted for "Capture Previous Area".
    static var lastRegion: StoredRegion? {
        get {
            guard let data = defaults.data(forKey: Key.lastRegion) else { return nil }
            return try? JSONDecoder().decode(StoredRegion.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Key.lastRegion)
                return
            }
            defaults.set(data, forKey: Key.lastRegion)
        }
    }

    /// User-saved beautify style presets, newest last.
    static var beautifyPresets: [BeautifyPreset] {
        get {
            guard let data = defaults.data(forKey: Key.beautifyPresets),
                  let list = try? JSONDecoder().decode([BeautifyPreset].self, from: data) else { return [] }
            return list
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.beautifyPresets)
        }
    }

    /// Name of a beautify preset to auto-apply to every capture (nil = off). Hold Shift while
    /// capturing to bypass it for that shot.
    static var autoBeautifyPresetName: String? {
        get { defaults.string(forKey: "autoBeautifyPresetName") }
        set { defaults.set(newValue, forKey: "autoBeautifyPresetName") }
    }

    /// Add or replace a preset by name.
    static func addBeautifyPreset(_ preset: BeautifyPreset) {
        var list = beautifyPresets.filter { $0.name != preset.name }
        list.append(preset)
        beautifyPresets = list
    }

    static func removeBeautifyPreset(named name: String) {
        beautifyPresets = beautifyPresets.filter { $0.name != name }
    }

    /// Path of an MP4 currently being recorded, for crash recovery. Nil when idle.
    static var recordingInProgressPath: String? {
        get { defaults.string(forKey: Key.recordingInProgressPath) }
        set { defaults.set(newValue, forKey: Key.recordingInProgressPath) }
    }

    /// Frame rate for screen recordings (30 or 60).
    static var recordingFPS: Int {
        get { let v = defaults.integer(forKey: Key.recordingFPS); return v == 0 ? 60 : v }
        set { defaults.set(newValue, forKey: Key.recordingFPS) }
    }

    /// Whether the first-run onboarding has been shown.
    static var hasOnboarded: Bool {
        get { defaults.bool(forKey: Key.hasOnboarded) }
        set { defaults.set(newValue, forKey: Key.hasOnboarded) }
    }

    /// Include the macOS drop shadow when capturing a single window. On by
    /// default so window screenshots keep the soft shadow that frames them,
    /// matching the native ⌘⇧4-Space look.
    static var includeWindowShadow: Bool {
        get { defaults.object(forKey: Key.includeWindowShadow) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.includeWindowShadow) }
    }

    /// Re-stroke the thin light outline along the window edge on single-window captures.
    /// WindowServer composites it at display time, so ScreenCaptureKit's window snapshot
    /// lacks it; on by default to match the native screenshot look.
    static var includeWindowBorder: Bool {
        get { defaults.object(forKey: Key.includeWindowBorder) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.includeWindowBorder) }
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

    /// Whether the mouse cursor appears in recordings.
    static var showCursorInRecording: Bool {
        get { defaults.object(forKey: Key.showCursorInRecording) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showCursorInRecording) }
    }

    static var recordSystemAudio: Bool {
        get { defaults.object(forKey: Key.recordSystemAudio) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.recordSystemAudio) }
    }

    /// Record the microphone as a second audio track.
    static var recordMicrophone: Bool {
        get { defaults.object(forKey: Key.recordMicrophone) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.recordMicrophone) }
    }

    /// Show the webcam bubble overlay during recordings.
    static var showWebcam: Bool {
        get { defaults.object(forKey: Key.showWebcam) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.showWebcam) }
    }

    /// Show pressed-key badges during recordings (needs Input Monitoring permission).
    static var showKeystrokes: Bool {
        get { defaults.object(forKey: Key.showKeystrokes) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.showKeystrokes) }
    }

    /// Automatically write every screenshot to the save location. When off, captures still go to
    /// the clipboard / preview / history; only the automatic file on disk is skipped. Explicit
    /// Save actions (action bar, editor, preview) always write.
    static var saveScreenshotsToDisk: Bool {
        get { defaults.object(forKey: Key.saveToDisk) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.saveToDisk) }
    }

    /// Keep a history of recognized (OCR) text, stored encrypted in the user's keychain.
    static var ocrHistoryEnabled: Bool {
        get { defaults.object(forKey: Key.ocrHistory) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.ocrHistory) }
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
        get { defaults.string(forKey: Key.filenameTemplate) ?? FilenameTemplate.defaultTemplate }
        set { defaults.set(newValue, forKey: Key.filenameTemplate) }
    }

    static var afterCaptureAction: AfterCaptureAction {
        get { AfterCaptureAction(rawValue: defaults.string(forKey: Key.afterCapture) ?? "") ?? .both }
        set { defaults.set(newValue.rawValue, forKey: Key.afterCapture) }
    }

    static var magnifierEnabled: Bool {
        // Off by default for a clean, Snapzy-style selection (no zoom loupe). Opt back in via Settings.
        get { defaults.object(forKey: Key.magnifier) as? Bool ?? false }
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
