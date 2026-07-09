import Darwin
import Foundation

/// Best-effort Focus / Do-Not-Disturb control around recordings. macOS exposes **no public API** to
/// toggle a Focus directly (CleanShot uses a private one we won't), so this runs a user-created
/// Shortcut by name via the `shortcuts` CLI — the only sanctioned path. Opt-in: empty name = no-op.
/// Requires the app to be non-sandboxed (it is) so it can spawn the helper.
nonisolated enum FocusController {
    private final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "app.bettershutter.focus-shortcut")
        var active: Process?
        var generation: UInt64 = 0

        func enqueue(_ name: String) {
            queue.async { self.start(name) }
        }

        private func start(_ name: String) {
            generation &+= 1
            let currentGeneration = generation
            if let active { terminateAndEscalate(active) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.terminationHandler = { [weak self, weak process] _ in
                guard let self, let process else { return }
                self.queue.async {
                    if self.generation == currentGeneration, self.active === process {
                        self.active = nil
                    }
                }
            }
            do {
                try process.run()
                active = process
            } catch {
                active = nil
                return
            }

            // A user Shortcut may contain an unbounded Wait. Keep the helper best-effort and bound
            // its lifetime; a newer start/stop invocation supersedes it even sooner.
            queue.asyncAfter(deadline: .now() + 30) { [weak self, weak process] in
                guard let self, let process,
                      self.generation == currentGeneration,
                      self.active === process,
                      process.isRunning else { return }
                self.terminateAndEscalate(process)
            }
        }

        private func terminateAndEscalate(_ process: Process) {
            guard process.isRunning else {
                if active === process { active = nil }
                return
            }
            process.terminate()
            let pid = process.processIdentifier
            queue.asyncAfter(deadline: .now() + 2) {
                if process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
            if active === process { active = nil }
        }
    }

    private static let state = State()

    static func run(shortcutNamed name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.enqueue(trimmed)
    }
}
