import Foundation

/// Best-effort Focus / Do-Not-Disturb control around recordings. macOS exposes **no public API** to
/// toggle a Focus directly (CleanShot uses a private one we won't), so this runs a user-created
/// Shortcut by name via the `shortcuts` CLI — the only sanctioned path. Opt-in: empty name = no-op.
/// Requires the app to be non-sandboxed (it is) so it can spawn the helper.
nonisolated enum FocusController {
    static func run(shortcutNamed name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", trimmed]
        try? process.run()   // fire-and-forget; failures (missing shortcut) are silent
    }
}
