import AppKit

/// Screen-Recording (TCC) gatekeeping. macOS only fully applies a fresh grant after the app
/// relaunches, so the denied path offers a "Quit & Relaunch" action.
@MainActor
final class PermissionsService {
    static let shared = PermissionsService()

    /// A guide alert is on screen — don't stack a second one when several flows fail at once.
    private var guideOnScreen = false

    /// Cheap synchronous check — does not prompt. Use to gate UI before showing the overlay.
    var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt the first time; returns the current state.
    @discardableResult
    func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    /// Gate a capture. Returns true to proceed.
    ///
    /// `CGPreflightScreenCaptureAccess()` is only a hint: it caches per-process and routinely
    /// reports a stale `false` even when access is granted — most visibly in a long-running
    /// menu-bar agent and after the in-place updater swaps the bundle out from under the running
    /// process. Blocking on that false was surfacing the "grant permission" alert while capture
    /// would actually have worked.
    ///
    /// So preflight-true is trusted as a fast path; on false we still proceed (firing the native
    /// prompt first in case the state is genuinely undetermined) and let ScreenCaptureKit be the
    /// authority. A real denial throws when the engine runs, and `handleCaptureError` turns that
    /// into the guidance alert — a stale false no longer blocks a working capture.
    @discardableResult
    func ensureAuthorizedOrGuide() -> Bool {
        if isAuthorized { return true }
        requestAccess()   // native prompt only while undetermined; silent once decided
        return true
    }

    /// Route a capture failure: if it's a Screen-Recording denial, show the guidance alert and
    /// report it handled; otherwise return false so the caller shows its own error.
    @discardableResult
    func handleCaptureError(_ error: Error) -> Bool {
        guard Self.isDenialError(error) else { return false }
        guideDenied()
        return true
    }

    /// Whether an error is ScreenCaptureKit / TCC reporting that screen recording is not permitted.
    static func isDenialError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain.contains("SCStreamError") || ns.domain.contains("ScreenCaptureKit") {
            // -3801 = userDeclined; treat the whole SCK error family as "not permitted" since the
            // engine only throws these when the capture itself can't proceed.
            return true
        }
        if ns.domain == "com.apple.TCC" { return true }
        return false
    }

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Show the "grant + relaunch" guidance alert (coalesced so concurrent failures show one).
    func guideDenied() {
        guard !guideOnScreen else { return }
        guideOnScreen = true
        defer { guideOnScreen = false }
        presentDeniedAlert()
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
