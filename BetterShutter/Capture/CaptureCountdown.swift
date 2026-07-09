import AppKit

/// A CleanShot-style self-timer: a floating glass badge that counts down from N seconds before a
/// capture fires, letting the user arrange the screen (open menus, hover tooltips) first. The badge
/// is click-through so it never blocks the scene being set up; Esc anywhere cancels.
@MainActor
final class CaptureCountdown {
    static let shared = CaptureCountdown()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var task: Task<Void, Never>?
    private var escMonitors: [Any] = []
    private var onCancel: (() -> Void)?
    private var generation: UInt64 = 0

    /// True while a countdown is running, so capture entry points can refuse to stack.
    private(set) var isActive = false

    private init() {}

    /// Count down `seconds`, then call `onComplete`. With `seconds <= 0` (or already counting) the
    /// completion runs immediately. `onCancel` fires if the user presses Esc before it elapses.
    func run(seconds: Int, onComplete: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        guard seconds > 0, !isActive else { onComplete(); return }
        generation &+= 1
        let runGeneration = generation
        isActive = true
        self.onCancel = onCancel
        present(initial: seconds)
        installEscMonitor(generation: runGeneration)

        task = Task { @MainActor in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                update(remaining)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled || generation != runGeneration { return }
            }
            guard generation == runGeneration else { return }
            teardown()
            onComplete()
        }
    }

    /// Cancel a running countdown (no capture). Safe to call when idle.
    func cancel() {
        guard isActive else { return }
        let onCancel = self.onCancel
        teardown()
        onCancel?()
    }

    // MARK: Presentation

    private func present(initial: Int) {
        let side: CGFloat = 132
        let panel = NSPanel.glassChrome(size: NSSize(width: side, height: side), level: .statusBar)
        panel.ignoresMouseEvents = true

        let glass = GlassPanelView(cornerRadius: 28)
        glass.frame = NSRect(x: 0, y: 0, width: side, height: side)

        let number = NSTextField(labelWithString: "\(initial)")
        number.font = .monospacedDigitSystemFont(ofSize: 64, weight: .semibold)
        number.textColor = .white
        number.alignment = .center
        number.frame = NSRect(x: 0, y: (side - 76) / 2, width: side, height: 76)
        glass.contentView.addSubview(number)
        panel.contentView = glass
        self.label = number

        // Center on the screen under the cursor so the timer appears where the user is working.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.frame {
            panel.setFrameOrigin(CGPoint(x: frame.midX - side / 2, y: frame.midY - side / 2))
        }
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        self.panel = panel
    }

    private func update(_ remaining: Int) {
        label?.stringValue = "\(remaining)"
    }

    private func installEscMonitor(generation: UInt64) {
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.generation == generation else { return false }
                self.cancel()
                return true
            }
            return handled ? nil : event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.cancel()
            }
        }
        escMonitors = [local, global].compactMap { $0 }
    }

    private func teardown() {
        generation &+= 1
        task?.cancel()
        task = nil
        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        label = nil
        onCancel = nil
        isActive = false
    }
}
