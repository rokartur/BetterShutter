import AppKit

/// Draws an expanding, fading ring at each mouse click on a transparent full-display overlay while
/// recording, so clicks are visible in the captured video (ScreenCaptureKit records the whole
/// display, overlay included). The overlay is click-through, so it never intercepts the clicks.
@MainActor
final class ClickHighlighter {
    static let shared = ClickHighlighter()

    private var window: NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?
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
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window

        // Mouse-event monitors need no accessibility grant (unlike keyboard). Global = other apps,
        // local = clicks on our own windows.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.ripple()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in self?.ripple(); return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        window?.orderOut(nil)
        window = nil
    }

    private func ripple() {
        guard let host = window?.contentView?.layer else { return }
        // mouseLocation is global, bottom-left; window origin is the display origin.
        let global = NSEvent.mouseLocation
        let center = CGPoint(x: global.x - displayFrame.minX, y: global.y - displayFrame.minY)
        let radius: CGFloat = 22

        let ring = CAShapeLayer()
        ring.frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2), transform: nil)
        ring.fillColor = NSColor.systemYellow.withAlphaComponent(0.30).cgColor
        ring.strokeColor = NSColor.systemYellow.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        host.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: nil)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            ring.removeFromSuperlayer()
        }
    }
}
