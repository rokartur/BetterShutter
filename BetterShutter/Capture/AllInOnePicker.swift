import AppKit

/// A single glass chooser that offers every capture mode at once (CleanShot's all-in-one entry):
/// Area, Window, Full Screen, Record, Scrolling. Esc or clicking away dismisses it.
@MainActor
final class AllInOnePicker: NSObject, NSWindowDelegate {
    static let shared = AllInOnePicker()

    enum Mode: String, CaseIterable {
        case area, window, fullScreen, record, scrolling
        var title: String {
            switch self {
            case .area: return "Area"
            case .window: return "Window"
            case .fullScreen: return "Full Screen"
            case .record: return "Record"
            case .scrolling: return "Scrolling"
            }
        }
        var symbol: String {
            switch self {
            case .area: return "viewfinder"
            case .window: return "macwindow"
            case .fullScreen: return "rectangle.inset.filled"
            case .record: return "record.circle"
            case .scrolling: return "arrow.up.and.down.text.horizontal"
            }
        }
    }

    private var window: NSPanel?
    private var monitor: Any?
    private var onPick: ((Mode) -> Void)?

    func show(onPick: @escaping (Mode) -> Void) {
        dismiss()
        self.onPick = onPick

        let buttonW: CGFloat = 96, buttonH: CGFloat = 86, gap: CGFloat = 10, pad: CGFloat = 18
        let modes = Mode.allCases
        let width = pad * 2 + CGFloat(modes.count) * buttonW + CGFloat(modes.count - 1) * gap
        let size = NSSize(width: width, height: buttonH + pad * 2)

        let panel = NSPanel.glassChrome(size: size, level: .statusBar)
        panel.delegate = self
        let glass = GlassPanelView(cornerRadius: 18)
        glass.frame = NSRect(origin: .zero, size: size)

        let row = NSStackView(views: modes.map { makeButton($0) })
        row.spacing = gap
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
        ])
        panel.contentView = glass

        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2,
                                         y: screen.frame.midY - size.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        window = panel

        // Esc to cancel; clicking away resigns key (see windowDidResignKey).
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(); return nil }
            return event
        }
    }

    func windowDidResignKey(_ notification: Notification) { dismiss() }

    private func makeButton(_ mode: Mode) -> NSButton {
        let button = NSButton(title: mode.title, target: self, action: #selector(pick(_:)))
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageAbove
        button.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        button.tag = Mode.allCases.firstIndex(of: mode) ?? 0
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 96).isActive = true
        button.heightAnchor.constraint(equalToConstant: 86).isActive = true
        return button
    }

    @objc private func pick(_ sender: NSButton) {
        guard Mode.allCases.indices.contains(sender.tag) else { return }
        let mode = Mode.allCases[sender.tag]
        let pick = onPick
        dismiss()
        pick?(mode)
    }

    func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.orderOut(nil)
        window = nil
        onPick = nil
    }
}
