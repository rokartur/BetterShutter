import AppKit

/// Pure sizing for a pinned window: image point-size, capped to a fraction of the screen.
nonisolated enum PinGeometry {
    static func fittedSize(pixelSize: CGSize, scale: CGFloat, maxSize: CGSize) -> CGSize {
        let s = max(scale, 1)
        let base = CGSize(width: pixelSize.width / s, height: pixelSize.height / s)
        guard base.width > 0, base.height > 0 else { return maxSize }
        let f = min(maxSize.width / base.width, maxSize.height / base.height, 1)
        return CGSize(width: (base.width * f).rounded(), height: (base.height * f).rounded())
    }

    static func clampOpacity(_ value: CGFloat) -> CGFloat { min(max(value, 0.2), 1.0) }
}

/// Manages floating "pinned" screenshots — always-on-top reference windows above all apps.
@MainActor
final class PinController {
    static let shared = PinController()

    private var pins: [PinWindow] = []

    var hasPins: Bool { !pins.isEmpty }

    func pin(_ image: CapturedImage) {
        let window = PinWindow(image: image) { [weak self] closed in
            self?.pins.removeAll { $0 === closed }
        }
        // Cascade each new pin slightly so stacked pins don't hide one another.
        if let screen = NSScreen.main {
            let offset = CGFloat(pins.count % 8) * 26
            let frame = window.frame
            let origin = CGPoint(x: screen.visibleFrame.midX - frame.width / 2 + offset,
                                 y: screen.visibleFrame.midY - frame.height / 2 - offset)
            window.setFrameOrigin(origin)
        }
        window.orderFrontRegardless()
        window.makeKey()
        pins.append(window)
    }

    func closeAll() {
        pins.forEach { $0.closePin() }
        pins.removeAll()
    }
}

/// A borderless floating panel hosting a pinned screenshot. Drag to move, scroll to change opacity,
/// arrow keys to nudge, middle-click or ⌘W/Esc to close, right-click for actions + click-through.
@MainActor
final class PinWindow: NSPanel {
    private let image: CapturedImage
    private let onClosed: (PinWindow) -> Void

    init(image: CapturedImage, onClosed: @escaping (PinWindow) -> Void) {
        self.image = image
        self.onClosed = onClosed
        let maxSize = (NSScreen.main?.visibleFrame.size).map { CGSize(width: $0.width * 0.6, height: $0.height * 0.6) }
            ?? CGSize(width: 800, height: 600)
        let size = PinGeometry.fittedSize(pixelSize: image.pixelSize, scale: image.scale, maxSize: maxSize)

        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true

        let view = PinImageView(image: image)
        view.onClose = { [weak self] in self?.closePin() }
        view.onCopy = { PasteboardWriter.copy(image.cgImage) }
        view.onEdit = { [weak self] in
            guard let self else { return }
            CaptureCoordinator.shared.edit(self.image, mode: .region)
            self.closePin()
        }
        view.onAdjustOpacity = { [weak self] delta in
            guard let self else { return }
            self.alphaValue = PinGeometry.clampOpacity(self.alphaValue + delta)
        }
        view.onNudge = { [weak self] dx, dy in
            guard let self else { return }
            self.setFrameOrigin(CGPoint(x: self.frame.minX + dx, y: self.frame.minY + dy))
        }
        view.onLockClickThrough = { [weak self] in
            self?.ignoresMouseEvents = true
            HUD.show("Pin locked — use “Close All Pins” to remove")
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    func closePin() {
        onClosed(self)
        orderOut(nil)
    }
}

/// The image surface of a pinned window. Forwards interactions to the window via closures.
@MainActor
private final class PinImageView: NSView {
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?
    var onAdjustOpacity: ((CGFloat) -> Void)?
    var onNudge: ((CGFloat, CGFloat) -> Void)?
    var onLockClickThrough: (() -> Void)?

    init(image: CapturedImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image.cgImage
        layer?.contentsGravity = .resizeAspect
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = GlassTokens.cg(GlassTokens.pinBorder, for: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = GlassTokens.cg(GlassTokens.pinBorder, for: self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event) // lets isMovableByWindowBackground drag the window
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() } // middle-click closes
    }

    override func scrollWheel(with event: NSEvent) {
        onAdjustOpacity?(event.scrollingDeltaY > 0 ? 0.05 : -0.05)
    }

    override func keyDown(with event: NSEvent) {
        let large = event.modifierFlags.contains(.shift)
        let step: CGFloat = large ? 10 : 1
        switch event.keyCode {
        case 53: onClose?()                       // esc
        case 123: onNudge?(-step, 0)              // left
        case 124: onNudge?(step, 0)               // right
        case 125: onNudge?(0, -step)             // down
        case 126: onNudge?(0, step)              // up
        case 13 where event.modifierFlags.contains(.command): onClose?() // ⌘W
        default: super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        item(menu, "Copy", #selector(copyAction))
        item(menu, "Open in Editor", #selector(editAction))
        menu.addItem(.separator())
        item(menu, "Lock (Click-Through)", #selector(lockAction))
        item(menu, "Close", #selector(closeAction))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        menu.addItem(i)
    }

    @objc private func copyAction() { onCopy?() }
    @objc private func editAction() { onEdit?() }
    @objc private func lockAction() { onLockClickThrough?() }
    @objc private func closeAction() { onClose?() }
}
