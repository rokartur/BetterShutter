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
    /// When not authorized it kicks off the request and shows guidance, returning false so the
    /// caller aborts this capture.
    @discardableResult
    func ensureAuthorizedOrGuide() -> Bool {
        if isAuthorized { return true }
        // Fire the system prompt (first run) then show our guidance covering the relaunch caveat.
        _ = requestAccess()
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
