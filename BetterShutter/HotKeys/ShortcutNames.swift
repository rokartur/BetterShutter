import AppKit
import BetterShortcuts

/// Strongly-typed global-shortcut names.
///
/// Screenshots default to the `⌃⇧` (Control-Shift) family and recording to the
/// `⌃⌥` (Control-Option) family. Both deliberately avoid the system's
/// `⌘⇧3/4/5/6` screenshot combos and the `⌘⇧`/`⌘` letter shortcuts apps rely on,
/// so a fresh install works out of the box without stealing anything in use.
/// A default only applies when the user has nothing stored for that name, so
/// existing users keep whatever they already assigned in Settings ▸ Shortcuts.
extension BetterShortcuts.Name {
    // Screenshots — ⌃⇧
    nonisolated static let allInOne = Self("allInOne", default: .init(.a, modifiers: [.control, .shift]))
    /// The merged screenshot flow (region drag; hold Space for window pick). Keeps the historical
    /// "quickScreenshot" storage key so existing users' bindings survive the merge.
    nonisolated static let captureScreenshot = Self("quickScreenshot", default: .init(.s, modifiers: [.control, .shift]))
    nonisolated static let screenshotEdit = Self("screenshotEdit", default: .init(.e, modifiers: [.control, .shift]))
    nonisolated static let captureFullScreen = Self("captureFullScreen", default: .init(.f, modifiers: [.control, .shift]))
    nonisolated static let captureText = Self("captureText", default: .init(.t, modifiers: [.control, .shift]))
    nonisolated static let captureCutout = Self("captureCutout", default: .init(.c, modifiers: [.control, .shift]))
    nonisolated static let captureScrolling = Self("captureScrolling", default: .init(.l, modifiers: [.control, .shift]))

    // Recording — ⌃⌥
    nonisolated static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.control, .option]))
    nonisolated static let recordRegion = Self("recordRegion", default: .init(.e, modifiers: [.control, .option]))
    nonisolated static let recordWindow = Self("recordWindow", default: .init(.w, modifiers: [.control, .option]))
    nonisolated static let recordGIF = Self("recordGIF", default: .init(.g, modifiers: [.control, .option]))
}
