import AppKit
import Quartz
import UniformTypeIdentifiers

/// One quick-access capture card, CleanShot/Snapzy-style: a rounded thumbnail at rest that reveals a
/// floating action toolbar and a dismiss button on hover. The whole thumbnail is a drag handle that
/// drags the capture out as a PNG; double-click opens the editor; space Quick-Looks the saved file.
@MainActor
final class FloatPreviewView: NSView, NSDraggingSource, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    /// Every quick-access card is a fixed 16:9 tile so the bottom-right stack reads as a clean,
    /// uniform column. The capture is aspect-fit inside (centered, with a thin dark frame for shots
    /// that aren't 16:9).
    static let cardWidth: CGFloat = 288
    static let cardHeight: CGFloat = 162   // 288 × 9/16 = exact 16:9
    static let cardSize = NSSize(width: cardWidth, height: cardHeight)

    /// Fixed 16:9 regardless of the capture's own aspect (kept as a function for call-site clarity).
    static func cardSize(for pixelSize: CGSize) -> NSSize { cardSize }

    private let corner: CGFloat = 14

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
        super.init(frame: NSRect(origin: .zero, size: Self.cardSize(for: image.pixelSize)))
        wantsLayer = true
        layer?.cornerRadius = corner
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        // Fixed 16:9 tile: a dark backing (the letterbox frame for non-16:9 captures) plus a
        // hairline border so the card separates from the desktop behind it.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        setupScrim()
        setupControls()
        setControls(visible: false, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Quick Look

    /// The on-disk file Quick Look can preview (nil for an unsaved card).
    var quickLookURL: URL? { savedURL }

    // Snapshotted when the panel opens so the nonisolated data-source reads need no actor hop.
    nonisolated(unsafe) private var previewURLs: [URL] = []

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            previewURLs = savedURL.map { [$0] } ?? []
            panel.dataSource = self
            panel.delegate = self
            panel.currentPreviewItemIndex = 0
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs.indices.contains(index) ? (previewURLs[index] as NSURL) : nil
    }

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
        // Fill the card width and center vertically; captures taller than 16:9 crop top/bottom
        // (the layer's rounded mask clips the overflow). The image always spans the full width.
        let scale = image.pixelSize.width > 0 ? bounds.width / image.pixelSize.width : 1
        let h = image.pixelSize.height * scale
        let dest = CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
        NSGraphicsContext.current?.cgContext.interpolationQuality = .high
        thumbnail.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
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
        let fit = Self.aspectFit(imageSize: image.pixelSize, in: bounds)
        item.setDraggingFrame(fit, contents: thumbnail)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
