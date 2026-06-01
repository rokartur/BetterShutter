import AppKit

/// A small, non-activating floating panel hosting one quick-access capture card. It can become key
/// (so it's interactive while hovered, and ⌘W can be routed to the app) but is non-activating so a
/// fresh capture never steals focus from the app the user is working in.
final class FloatPreviewWindow: NSPanel {

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false   // dragging the card drags the file out, not the window
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
}
