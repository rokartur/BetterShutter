import AppKit

/// A small floating bar shown while recording: a pulsing red dot, elapsed time, a pause/resume
/// button, and a stop button.
@MainActor
final class RecordingControlBar {
    private var window: NSPanel?
    private var timer: Timer?
    private var startDate = Date()
    private var pausedAccum: TimeInterval = 0
    private var pauseStart: Date?
    private var paused = false
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let dot = NSImageView()
    private let pauseButton = NSButton()

    var onStop: (() -> Void)?
    var onTogglePause: (() -> Void)?

    /// The control bar's window id, so the recorder can exclude it from the captured video.
    var windowID: CGWindowID? { window.map { CGWindowID($0.windowNumber) } }

    func show(canPause: Bool) {
        let size = NSSize(width: canPause ? 220 : 168, height: 40)
        let panel = NSPanel.glassChrome(size: size, level: .statusBar)

        let glass = GlassPanelView(cornerRadius: 14)
        glass.frame = NSRect(origin: .zero, size: size)
        let container = glass.contentView

        dot.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
        dot.contentTintColor = .systemRed
        dot.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.stringValue = "0:00"

        var views = [NSView]()
        views.append(dot)
        views.append(timeLabel)
        if canPause {
            paused = false
            pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
            pauseButton.imagePosition = .imageOnly
            pauseButton.bezelStyle = .accessoryBarAction
            pauseButton.controlSize = .small
            pauseButton.target = self
            pauseButton.action = #selector(pauseTapped)
            pauseButton.toolTip = "Pause"
            views.append(pauseButton)
        }
        let stop = NSButton(title: "Stop", target: self, action: #selector(stopTapped))
        stop.bezelStyle = .accessoryBarAction
        stop.controlSize = .small
        views.append(stop)

        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        panel.contentView = glass

        if let screen = NSScreen.main {
            let x = screen.frame.midX - size.width / 2
            let y = screen.visibleFrame.maxY - size.height - 12
            panel.setFrameOrigin(CGPoint(x: x, y: y))
        }
        panel.orderFront(nil)
        window = panel

        startDate = Date()
        pausedAccum = 0
        pauseStart = nil
        updateLabel()
        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }

    /// Reflect paused state: stop counting elapsed time and swap the button glyph / dot tint.
    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        if value {
            pauseStart = Date()
        } else if let start = pauseStart {
            pausedAccum += Date().timeIntervalSince(start)
            pauseStart = nil
        }
        pauseButton.image = NSImage(systemSymbolName: value ? "play.fill" : "pause.fill",
                                    accessibilityDescription: value ? "Resume" : "Pause")
        pauseButton.toolTip = value ? "Resume" : "Pause"
        dot.contentTintColor = value ? .systemGray : .systemRed
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func pauseTapped() { onTogglePause?() }

    @objc private func tick() { updateLabel() }

    private func updateLabel() {
        // Elapsed = wall-clock since start, minus time spent paused (avoids whole-second drift).
        var elapsed = Date().timeIntervalSince(startDate) - pausedAccum
        if let pauseStart { elapsed -= Date().timeIntervalSince(pauseStart) }
        let total = Int(max(0, elapsed))
        timeLabel.stringValue = String(format: "%d:%02d", total / 60, total % 60)
    }
}
