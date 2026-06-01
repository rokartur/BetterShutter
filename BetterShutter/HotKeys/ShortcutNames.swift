import BetterShortcuts

/// Strongly-typed global-shortcut names. Intentionally shipped with NO default combos so we don't
/// steal the user's existing ⌘⇧3/4/5 — they assign their own in Settings ▸ Shortcuts.
extension BetterShortcuts.Name {
    nonisolated static let captureRegion = Self("captureRegion")
    nonisolated static let captureWindow = Self("captureWindow")
    nonisolated static let captureFullScreen = Self("captureFullScreen")
    nonisolated static let captureText = Self("captureText")
    nonisolated static let toggleRecording = Self("toggleRecording")
}
