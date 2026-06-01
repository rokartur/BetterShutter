import AppKit
import BetterShortcuts

/// Wires the global shortcuts (via BetterShortcuts) to the capture coordinator, and exposes the
/// current combo for a given action so menu items can mirror it.
@MainActor
enum HotKeyBridge {
    static func install() {
        BetterShortcuts.onKeyDown(for: .captureRegion) {
            MainActor.assumeIsolated { CaptureCoordinator.shared.capture(.region) }
        }
        BetterShortcuts.onKeyDown(for: .captureWindow) {
            MainActor.assumeIsolated { CaptureCoordinator.shared.capture(.window) }
        }
        BetterShortcuts.onKeyDown(for: .captureFullScreen) {
            MainActor.assumeIsolated { CaptureCoordinator.shared.capture(.fullDisplay) }
        }
        BetterShortcuts.onKeyDown(for: .captureText) {
            MainActor.assumeIsolated { CaptureCoordinator.shared.captureText() }
        }
        BetterShortcuts.onKeyDown(for: .toggleRecording) {
            MainActor.assumeIsolated { RecordingController.shared.toggle() }
        }
        BetterShortcuts.onKeyDown(for: .recordRegion) {
            MainActor.assumeIsolated { CaptureCoordinator.shared.recordRegion() }
        }

        // Friendly labels in the recorder's conflict alert.
        BetterShortcuts.displayName = { name in
            if name == .captureRegion { return "Capture Region" }
            if name == .captureWindow { return "Capture Window" }
            if name == .captureFullScreen { return "Capture Full Screen" }
            if name == .captureText { return "Capture Text (OCR)" }
            if name == .toggleRecording { return "Start / Stop Recording" }
            if name == .recordRegion { return "Record Region" }
            return name.rawValue
        }
    }

    /// The menu key-equivalent (character + modifier mask) for a shortcut name, if assigned.
    static func menuKeyEquivalent(for name: BetterShortcuts.Name) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let shortcut = name.shortcut, let key = shortcut.nsMenuItemKeyEquivalent else { return nil }
        return (key, shortcut.modifiers)
    }
}
