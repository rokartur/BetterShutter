import AppKit

/// Screen-Recording (TCC) gatekeeping. macOS only fully applies a fresh grant after the app
/// relaunches, so the denied path offers a "Quit & Relaunch" action.
@MainActor
final class PermissionsService {
    static let shared = PermissionsService()

    /// Cheap synchronous check — does not prompt. Use to gate UI before showing the overlay.
    var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt the first time; returns the current state.
    @discardableResult
    func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    /// Ensures access, prompting / guiding the user if needed. Returns true if already authorized.
    /// When not authorized it returns false so the caller aborts this capture.
    ///
    /// `requestAccess()` shows the native TCC prompt only while the state is "not determined". Once
    /// macOS has a stored decision it returns silently and never re-prompts (an app relaunch does
    /// NOT reset this — only `tccutil reset ScreenCapture <bundleID>` does), so we fall back to our
    /// own guidance alert pointing at System Settings + relaunch.
    @discardableResult
    func ensureAuthorizedOrGuide() -> Bool {
        if isAuthorized { return true }
        if requestAccess() { return true }   // native prompt if undetermined; silent if already decided
        presentDeniedAlert()
        return false
    }

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    private func presentDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = """
        BetterShutter needs Screen Recording access to capture your screen.

        Enable it in System Settings ▸ Privacy & Security ▸ Screen Recording, then relaunch \
        BetterShutter for the change to take effect.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit & Relaunch")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openSystemSettings()
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
    }

    /// Relaunch the app (allowed because we are not sandboxed). Used after granting access.
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
