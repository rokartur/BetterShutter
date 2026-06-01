import AppKit

/// A small floating bar shown while recording: a pulsing red dot, elapsed time, and a stop button.
@MainActor
final class RecordingControlBar {
    private var window: NSPanel?
    private var timer: Timer?
    private var seconds = 0
    private let timeLabel = NSTextField(labelWithString: "0:00")

    var onStop: (() -> Void)?

    func show() {
        let size = NSSize(width: 168, height: 40)
        let panel = NSPanel.glassChrome(size: size, level: .statusBar)

        let glass = GlassPanelView(cornerRadius: 14)
        glass.frame = NSRect(origin: .zero, size: size)
        let container = glass.contentView

        let dot = NSImageView(image: NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")!)
        dot.contentTintColor = .systemRed
        dot.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.stringValue = "0:00"

        let stop = NSButton(title: "Stop", target: self, action: #selector(stopTapped))
        stop.bezelStyle = .accessoryBarAction
        stop.controlSize = .small
        stop.keyEquivalent = ""

        let stack = NSStackView(views: [dot, timeLabel, stop])
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

        seconds = 0
        updateLabel()
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }

    @objc private func stopTapped() { onStop?() }

    @objc private func tick() {
        seconds += 1
        updateLabel()
    }

    private func updateLabel() {
        timeLabel.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
