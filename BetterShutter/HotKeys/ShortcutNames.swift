import AppKit
import BetterShortcuts

/// Strongly-typed global-shortcut names.
///
/// Screenshot and recording defaults take over the system's `⌘⇧1…6` screenshot combos;
/// the macOS ones must be turned off in System Settings ▸ Keyboard ▸ Shortcuts for these to fire.
/// A default only applies when the user has nothing stored for that name, so
/// existing users keep whatever they already assigned in Settings ▸ Shortcuts.
extension BetterShortcuts.Name {
    nonisolated static let allInOne = Self("allInOne")
    /// The merged screenshot flow (region drag; hold Space for window pick). Keeps the historical
    /// "quickScreenshot" storage key so existing users' bindings survive the merge.
    nonisolated static let captureScreenshot = Self("quickScreenshot", default: .init(.four, modifiers: [.command, .shift]))
    nonisolated static let screenshotEdit = Self("screenshotEdit")
    nonisolated static let captureFullScreen = Self("captureFullScreen", default: .init(.three, modifiers: [.command, .shift]))
    nonisolated static let captureText = Self("captureText", default: .init(.t, modifiers: [.control, .shift]))
    nonisolated static let captureCutout = Self("captureCutout")
    nonisolated static let captureScrolling = Self("captureScrolling", default: .init(.one, modifiers: [.command, .shift]))

    nonisolated static let toggleRecording = Self("toggleRecording", default: .init(.six, modifiers: [.command, .shift]))
    nonisolated static let recordRegion = Self("recordRegion", default: .init(.e, modifiers: [.control, .option]))
    nonisolated static let recordWindow = Self("recordWindow", default: .init(.w, modifiers: [.control, .option]))
    nonisolated static let recordGIF = Self("recordGIF", default: .init(.g, modifiers: [.control, .option]))
}
