import AppKit

/// A pre-capture countdown: shows a big glass number that ticks down, then fires a completion so
/// the user can set up hover states, menus, or arrange windows before the shot. A Cancel button
/// aborts (works even while another app is focused, since this is a menu-bar agent).
@MainActor
final class SelfTimer {
    static let shared = SelfTimer()

    private var panel: NSPanel?
    private var timer: Timer?
    private var remaining = 0
    private var onFire: (() -> Void)?
    private let numberLabel = NSTextField(labelWithString: "")

    /// Count down `seconds`, then call `onFire`. Restarts cleanly if already running.
    func run(seconds: Int, onFire: @escaping () -> Void) {
        cancel()
        remaining = max(1, seconds)
        self.onFire = onFire
        showPanel()
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    @objc func cancel() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil
        onFire = nil
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 { fire() } else { update() }
    }

    private func fire() {
        let callback = onFire
        cancel()
        callback?()
    }

    private func update() {
        numberLabel.stringValue = "\(remaining)"
    }

    private func showPanel() {
        let size = NSSize(width: 170, height: 190)
        let glass = GlassPanelView(cornerRadius: 28)
        glass.frame = NSRect(origin: .zero, size: size)

        numberLabel.font = .systemFont(ofSize: 76, weight: .bold)
        numberLabel.textColor = .labelColor
        numberLabel.alignment = .center

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .accessoryBarAction
        cancelButton.controlSize = .small

        let stack = NSStackView(views: [numberLabel, cancelButton])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
        ])

        let panel = NSPanel.glassChrome(size: size, level: .statusBar)
        panel.contentView = glass
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}
