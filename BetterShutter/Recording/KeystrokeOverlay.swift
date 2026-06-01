import AppKit

/// Shows pressed key combinations as fading badges along the bottom of the recorded display, so they
/// appear in the captured video (ScreenCaptureKit records the overlay too). The overlay is
/// click-through. Capturing keys needs Input Monitoring permission; without it the global monitor is
/// silently inert and no badges appear (the recording is otherwise unaffected).
@MainActor
final class KeystrokeOverlay {
    static let shared = KeystrokeOverlay()

    private var window: NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var stack: NSStackView?
    private var displayFrame: CGRect = .zero

    func start(displayID: CGDirectDisplayID) {
        stop()
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) ?? NSScreen.main
        else { return }
        displayFrame = screen.frame

        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -64),
        ])
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
        self.stack = stack

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.show(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.show(event); return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        window?.orderOut(nil)
        window = nil
        stack = nil
    }

    private func show(_ event: NSEvent) {
        let text = KeystrokeFormatter.display(modifiers: event.modifierFlags, keyCode: event.keyCode,
                                              characters: event.charactersIgnoringModifiers)
        guard !text.isEmpty, let stack else { return }

        let badge = makeBadge(text)
        stack.addArrangedSubview(badge)
        // Cap the row so it never runs off-screen.
        while stack.arrangedSubviews.count > 6, let first = stack.arrangedSubviews.first {
            stack.removeArrangedSubview(first)
            first.removeFromSuperview()
        }

        badge.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            badge.animator().alphaValue = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                badge.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    stack.removeArrangedSubview(badge)
                    badge.removeFromSuperview()
                }
            })
        }
    }

    private func makeBadge(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        pill.layer?.cornerRadius = 10
        pill.layer?.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -7),
            pill.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        return pill
    }
}
