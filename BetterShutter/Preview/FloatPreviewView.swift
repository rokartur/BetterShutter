import AppKit
import UniformTypeIdentifiers

/// One quick-access capture card, CleanShot/Snapzy-style: a rounded thumbnail at rest that reveals a
/// floating action toolbar and a dismiss button on hover. The whole thumbnail is a drag handle that
/// drags the capture out as a PNG; double-click opens the editor.
@MainActor
final class FloatPreviewView: NSView, NSDraggingSource {

    static let cardSize = NSSize(width: 256, height: 196)
    private let corner: CGFloat = 16

    private let image: CapturedImage
    private let mode: CaptureMode
    private let savedURL: URL?

    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onBeautify: (() -> Void)?
    var onPin: (() -> Void)?
    var onShare: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private var dragOrigin: CGPoint?
    private var activePromiseDelegate: ImageFilePromiseDelegate?
    private var trackingArea: NSTrackingArea?
    private let thumbnail: NSImage

    private let toolbar = NSView()
    private let closeButton = NSButton()
    private let scrim = CAGradientLayer()
    private var controlsVisible = false

    init(image: CapturedImage, mode: CaptureMode, savedURL: URL?) {
        self.image = image
        self.mode = mode
        self.savedURL = savedURL
        self.thumbnail = NSImage(cgImage: image.cgImage, size: image.pixelSize)
        super.init(frame: NSRect(origin: .zero, size: Self.cardSize))
        wantsLayer = true
        layer?.cornerRadius = corner
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        setupScrim()
        setupControls()
        setControls(visible: false, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    // MARK: Controls

    /// A bottom gradient so the toolbar icons stay legible over bright screenshots. Only visible with
    /// the toolbar.
    private func setupScrim() {
        // Dark end at the BOTTOM (under the toolbar). Layer geometry is bottom-up, so start at the
        // top (clear) and end at the bottom (black).
        scrim.colors = [
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.55).cgColor,
        ]
        scrim.startPoint = CGPoint(x: 0.5, y: 1)
        scrim.endPoint = CGPoint(x: 0.5, y: 0)
        scrim.locations = [0.45, 1.0]
        scrim.cornerRadius = corner
        scrim.cornerCurve = .continuous
        layer?.addSublayer(scrim)
    }

    private func setupControls() {
        let edit = makeIconButton("pencil.tip.crop.circle", "Edit", #selector(editTapped))
        let copy = makeIconButton("doc.on.doc", "Copy", #selector(copyTapped))
        let secondary = (savedURL != nil)
            ? makeIconButton("folder", "Show in Finder", #selector(revealTapped))
            : makeIconButton("arrow.down.circle", "Save", #selector(saveTapped))
        let share = makeIconButton("square.and.arrow.up", "Share", #selector(shareTapped))
        let pin = makeIconButton("pin", "Pin to Screen", #selector(pinTapped))

        let stack = NSStackView(views: [edit, copy, secondary, share, pin])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        toolbar.layer?.cornerRadius = 13
        toolbar.layer?.cornerCurve = .continuous
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        addSubview(toolbar)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -5),
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.bezelStyle = .regularSquare
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Dismiss (⌘W)"
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        closeButton.layer?.cornerRadius = 11
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    private func makeIconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func setControls(visible: Bool, animated: Bool) {
        guard visible != controlsVisible || !animated else { return }
        controlsVisible = visible
        if visible { toolbar.isHidden = false; closeButton.isHidden = false; scrim.isHidden = false }
        let apply = {
            self.toolbar.animator().alphaValue = visible ? 1 : 0
            self.closeButton.animator().alphaValue = visible ? 1 : 0
            self.scrim.opacity = visible ? 1 : 0
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                apply()
            }, completionHandler: {
                MainActor.assumeIsolated {
                    // Re-check: a fresh hover may have re-shown the controls during the fade.
                    if !visible, !self.controlsVisible {
                        self.toolbar.isHidden = true
                        self.closeButton.isHidden = true
                        self.scrim.isHidden = true
                    }
                }
            })
        } else {
            toolbar.alphaValue = visible ? 1 : 0
            closeButton.alphaValue = visible ? 1 : 0
            scrim.opacity = visible ? 1 : 0
            toolbar.isHidden = !visible
            closeButton.isHidden = !visible
            scrim.isHidden = !visible
        }
    }

    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func editTapped() { onAnnotate?() }
    @objc private func beautifyTapped() { onBeautify?() }
    @objc private func pinTapped() { onPin?() }
    @objc private func shareTapped() { onShare?() }
    @objc private func printTapped() { Printing.printImage(image.cgImage) }
    @objc private func revealTapped() {
        if let url = savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        addMenuItem(menu, "Annotate", #selector(editTapped))
        addMenuItem(menu, "Beautify", #selector(beautifyTapped))
        addMenuItem(menu, "Pin to Screen", #selector(pinTapped))
        addMenuItem(menu, "Share…", #selector(shareTapped))
        addMenuItem(menu, "Print…", #selector(printTapped))
        menu.addItem(.separator())
        addMenuItem(menu, "Copy", #selector(copyTapped))
        if savedURL != nil {
            addMenuItem(menu, "Show in Finder", #selector(revealTapped))
        } else {
            addMenuItem(menu, "Save", #selector(saveTapped))
        }
        menu.addItem(.separator())
        addMenuItem(menu, "Close", #selector(closeTapped))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func addMenuItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: Drawing

    override func layout() {
        super.layout()
        scrim.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        // Thumbnail aspect-fit on a dark mat so any letterboxing reads as part of the image well
        // rather than bare glass. The glass backdrop shows through the mat's translucency.
        let inset = bounds.insetBy(dx: 6, dy: 6)
        let fit = Self.aspectFit(imageSize: image.pixelSize, in: inset)
        let mat = NSBezierPath(roundedRect: fit.insetBy(dx: -1, dy: -1), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.25).setFill()
        mat.fill()
        NSGraphicsContext.current?.cgContext.interpolationQuality = .high
        let clip = NSBezierPath(roundedRect: fit, xRadius: 8, yRadius: 8)
        NSGraphicsContext.current?.saveGraphicsState()
        clip.addClip()
        thumbnail.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private static func aspectFit(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setControls(visible: true, animated: true)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        setControls(visible: false, animated: true)
        onHoverChange?(false)
    }

    /// Force the hover chrome on/off without re-firing `onHoverChange` — used by the controller when a
    /// card slides under a stationary pointer (which emits no synthetic mouseEntered).
    func setHoverVisual(_ visible: Bool) {
        setControls(visible: visible, animated: true)
    }

    /// Accept the click that also activates the app, so a drag-out / double-click on a fresh card
    /// from another app isn't swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drag-out

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            dragOrigin = nil
            onAnnotate?()
            return
        }
        dragOrigin = p
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - origin.x, p.y - origin.y) > 6 else { return }
        dragOrigin = nil
        beginDragOut(with: event)
    }

    private func beginDragOut(with event: NSEvent) {
        guard let png = ImageEncoder.encode(image.cgImage, as: .png) else { return }
        let filename = FilenameTemplate.render(
            Preferences.filenameTemplate, mode: mode, format: .png, counter: 0
        )
        let delegate = ImageFilePromiseDelegate(pngData: png, filename: filename)
        activePromiseDelegate = delegate

        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: delegate)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let fit = Self.aspectFit(imageSize: image.pixelSize, in: bounds.insetBy(dx: 6, dy: 6))
        item.setDraggingFrame(fit, contents: thumbnail)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
