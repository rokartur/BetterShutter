import AppKit

/// The floating bar shown while recording, laid out like CleanShot X 5.0.1's: a red stop button with
/// the elapsed time, then pause, restart and discard cells, and a drag handle, split by hairlines.
@MainActor
final class RecordingControlBar {
    private var window: NSPanel?
    private var timer: Timer?
    private var startDate = Date()
    private var pausedAccum: TimeInterval = 0
    private var pauseStart: Date?
    private var paused = false
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let pauseButton = NSButton()

    var onStop: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onRestart: (() -> Void)?
    var onDiscard: (() -> Void)?

    /// The control bar's window id, so the recorder can exclude it from the captured video.
    var windowID: CGWindowID? { window.map { CGWindowID($0.windowNumber) } }

    private static let height: CGFloat = 44
    private static let stopCellWidth: CGFloat = 76
    private static let iconCellWidth: CGFloat = 43
    private static let handleCellWidth: CGFloat = 26
    private static let red = NSColor(srgbRed: 0.93, green: 0.36, blue: 0.33, alpha: 1)

    func show(canPause: Bool) {
        let iconCells: CGFloat = canPause ? 3 : 2
        let size = NSSize(width: Self.stopCellWidth + iconCells * Self.iconCellWidth + Self.handleCellWidth,
                          height: Self.height)
        let panel = NSPanel.glassChrome(size: size, level: .statusBar)
        panel.isMovableByWindowBackground = true

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.97).cgColor
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = Self.red
        let stop = iconButton("stop.circle", "Stop Recording", #selector(stopTapped), tint: Self.red)
        let stopCell = NSStackView(views: [stop, timeLabel])
        stopCell.spacing = 6

        var cells: [(NSView, CGFloat)] = [(stopCell, Self.stopCellWidth)]
        if canPause {
            paused = false
            configurePauseButton()
            cells.append((pauseButton, Self.iconCellWidth))
        }
        cells.append((iconButton("arrow.counterclockwise", "Restart", #selector(restartTapped)), Self.iconCellWidth))
        cells.append((iconButton("trash", "Delete Recording", #selector(discardTapped), size: 15), Self.iconCellWidth))
        let handle = NSImageView(image: Self.grip)
        handle.contentTintColor = NSColor.white.withAlphaComponent(0.3)
        cells.append((handle, Self.handleCellWidth))

        var x: CGFloat = 0
        for (index, (view, width)) in cells.enumerated() {
            if index > 0 {
                let separator = NSView(frame: NSRect(x: x, y: 0, width: 1, height: size.height))
                separator.wantsLayer = true
                separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
                background.addSubview(separator)
            }
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: background.leadingAnchor, constant: x + width / 2),
                view.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            ])
            x += width
        }
        panel.contentView = background

        if let screen = NSScreen.main {
            let origin = CGPoint(x: screen.frame.midX - size.width / 2,
                                 y: screen.visibleFrame.maxY - size.height - 12)
            panel.setFrameOrigin(origin)
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

    /// Reflect paused state: stop counting elapsed time and swap the pause glyph for play.
    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        if value {
            pauseStart = Date()
        } else if let start = pauseStart {
            pausedAccum += Date().timeIntervalSince(start)
            pauseStart = nil
        }
        configurePauseButton()
    }

    private func configurePauseButton() {
        pauseButton.image = symbol(paused ? "play.circle" : "pause.circle", size: 17, weight: .regular)
        pauseButton.toolTip = paused ? "Resume" : "Pause"
        pauseButton.setAccessibilityLabel(pauseButton.toolTip)
        pauseButton.isBordered = false
        pauseButton.imagePosition = .imageOnly
        pauseButton.contentTintColor = .white
        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
    }

    /// Three short stacked dashes, CleanShot's drag grip.
    private static let grip: NSImage = {
        let image = NSImage(size: NSSize(width: 6, height: 10), flipped: false) { _ in
            NSColor.black.setFill()
            for y in [0.0, 4.25, 8.5] {
                NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: 6, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    private func iconButton(_ name: String, _ tip: String, _ action: Selector,
                            tint: NSColor = .white, size: CGFloat = 17) -> NSButton {
        let button = NSButton(image: symbol(name, size: size, weight: .regular), target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = tint
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return button
    }

    private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        return image.withSymbolConfiguration(GlassTokens.symbol(size, weight))!
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func pauseTapped() { onTogglePause?() }
    @objc private func restartTapped() { onRestart?() }

    @objc private func discardTapped() {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to delete this recording?"
        alert.informativeText = "The file is moved to the Trash."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDiscard?()
    }

    @objc private func tick() { updateLabel() }

    private func updateLabel() {
        // Elapsed = wall-clock since start, minus time spent paused (avoids whole-second drift).
        var elapsed = Date().timeIntervalSince(startDate) - pausedAccum
        if let pauseStart { elapsed -= Date().timeIntervalSince(pauseStart) }
        let total = Int(max(0, elapsed))
        timeLabel.stringValue = String(format: "%d:%02d", total / 60, total % 60)
    }
}
