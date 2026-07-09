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

/// Legacy single-popup after-capture choice. Kept only to migrate old installs to the
/// per-action matrix (`AfterCaptureItem`); no UI offers it anymore.
nonisolated enum AfterCaptureAction: String, CaseIterable, Sendable {
    case both       // copy to pasteboard AND show the float preview
    case preview    // show the float preview only
    case copy       // copy to pasteboard only

    var copies: Bool { self == .both || self == .copy }
    var previews: Bool { self == .both || self == .preview }
}

/// The two columns of the After-Capture actions matrix.
nonisolated enum CaptureMediaType: String, CaseIterable, Sendable {
    case screenshot
    case recording

    var presentableName: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .recording: return "Recording"
        }
    }
}

/// One row of the After-Capture actions matrix (CleanShot-style): each action can be toggled
/// independently per media type, and some actions only exist for one media type.
nonisolated enum AfterCaptureItem: String, CaseIterable, Sendable {
    case quickAccess
    case copy
    case save
    case upload
    case annotate
    case pin
    case videoEditor

    var presentableName: String {
        switch self {
        case .quickAccess: return "Show Quick Access Overlay"
        case .copy: return "Copy file to clipboard"
        case .save: return "Save"
        case .upload: return "Upload to Cloud & copy link"
        case .annotate: return "Open Annotate tool"
        case .pin: return "Pin to the screen"
        case .videoEditor: return "Open Video Editor"
        }
    }

    /// Whether this action exists for the media type; the settings matrix shows a dash otherwise.
    func applies(to media: CaptureMediaType) -> Bool {
        switch self {
        case .annotate, .pin: return media == .screenshot
        case .videoEditor: return media == .recording
        case .quickAccess, .copy, .save, .upload: return true
        }
    }

    /// The screenshot column an old install starts with, derived from the legacy popup value.
    static func migratedScreenshotActions(from legacy: AfterCaptureAction) -> Set<AfterCaptureItem> {
        var set: Set<AfterCaptureItem> = []
        if legacy.previews { set.insert(.quickAccess) }
        if legacy.copies { set.insert(.copy) }
        return set
    }

    /// Recording-column default: keep the file (recordings always saved before the matrix existed)
    /// and surface it as a quick-access card.
    static let defaultRecordingActions: Set<AfterCaptureItem> = [.quickAccess, .save]
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

/// Size of the Quick Access (float preview) cards. Only the width is stored here; the card keeps a
/// fixed 16:9 shape, so height derives from width at the call site.
nonisolated enum QuickAccessSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large
    case extraLarge

    var cardWidth: CGFloat {
        switch self {
        case .small: return 176
        case .medium: return 224
        case .large: return 288
        case .extraLarge: return 360
        }
    }

    var presentableName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }
}

/// Which screen edge the Quick Access card column anchors to.
nonisolated enum QuickAccessSide: String, CaseIterable, Sendable {
    case left
    case right

    var presentableName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// Thread-safe app preferences backed by `UserDefaults`. Accessor-only (no isolation) so the
/// capture actor and main-actor UI can both read it. Hotkeys persist themselves via BetterShortcuts.
nonisolated enum Preferences {
    private static var defaults: UserDefaults { .standard }
    /// UserDefaults protects individual calls, not a read-modify-write sequence. Screenshot saves
    /// and recording finalization can request `{n}` concurrently on different executors.
    private static let captureCounterLock = NSLock()

    private enum Key {
        static let saveDirectory = "saveDirectoryPath"
        static let saveToDisk = "saveScreenshotsToDisk"
        static let ocrHistory = "ocrHistoryEnabled"
        static let format = "imageFormat"
        static let jpegQuality = "jpegQuality"
        static let filenameTemplate = "filenameTemplate"
        static let afterCapture = "afterCaptureAction"
        static let afterScreenshot = "afterScreenshotActions"
        static let afterRecording = "afterRecordingActions"
        static let quickAccessSize = "quickAccessSize"
        static let quickAccessSide = "quickAccessSide"
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

    /// Legacy popup value, read only to seed the screenshot column of the actions matrix.
    private static var legacyAfterCaptureAction: AfterCaptureAction {
        AfterCaptureAction(rawValue: defaults.string(forKey: Key.afterCapture) ?? "") ?? .both
    }

    /// The enabled After-Capture matrix cells for a media type. The screenshot Save and Upload
    /// cells proxy the long-standing `saveScreenshotsToDisk` / `uploadAfterCapture` keys, so the
    /// matrix, the Output tab, and the Cloud tab always agree.
    static func afterCaptureActions(for media: CaptureMediaType) -> Set<AfterCaptureItem> {
        let key = media == .screenshot ? Key.afterScreenshot : Key.afterRecording
        var set: Set<AfterCaptureItem>
        if let raw = defaults.stringArray(forKey: key) {
            set = Set(raw.compactMap(AfterCaptureItem.init(rawValue:)))
        } else if media == .screenshot {
            set = AfterCaptureItem.migratedScreenshotActions(from: legacyAfterCaptureAction)
        } else {
            set = AfterCaptureItem.defaultRecordingActions
        }
        if media == .screenshot {
            set.remove(.save)
            set.remove(.upload)
            if saveScreenshotsToDisk { set.insert(.save) }
            if uploadAfterCapture { set.insert(.upload) }
        }
        return Set(set.filter { $0.applies(to: media) })
    }

    static func setAfterCaptureAction(_ item: AfterCaptureItem, for media: CaptureMediaType, enabled: Bool) {
        guard item.applies(to: media) else { return }
        if media == .screenshot {
            switch item {
            case .save: saveScreenshotsToDisk = enabled; return
            case .upload: uploadAfterCapture = enabled; return
            default: break
            }
        }
        var set = afterCaptureActions(for: media)
        if enabled { set.insert(item) } else { set.remove(item) }
        let key = media == .screenshot ? Key.afterScreenshot : Key.afterRecording
        defaults.set(set.map(\.rawValue).sorted(), forKey: key)
    }

    static var quickAccessSize: QuickAccessSize {
        get { QuickAccessSize(rawValue: defaults.string(forKey: Key.quickAccessSize) ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Key.quickAccessSize) }
    }

    static var quickAccessSide: QuickAccessSide {
        get { QuickAccessSide(rawValue: defaults.string(forKey: Key.quickAccessSide) ?? "") ?? .right }
        set { defaults.set(newValue.rawValue, forKey: Key.quickAccessSide) }
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
        captureCounterLock.withLock {
            let next = defaults.integer(forKey: Key.captureCounter) + 1
            defaults.set(next, forKey: Key.captureCounter)
            return next
        }
    }
}
