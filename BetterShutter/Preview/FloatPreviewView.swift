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
    static let cardWidth: CGFloat = 224
    static let cardHeight: CGFloat = 126   // 224 × 9/16 = exact 16:9
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

    private let toolbar = GlassPanelView(cornerRadius: GlassTokens.Radius.bar)
    private var closeButton: NSView!
    private let scrim = CAGradientLayer()
    private var controlsVisible = false
    private var copyBadge: NSView?

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
        // Fixed 16:9 tile: a backing (the letterbox frame for non-16:9 captures) plus a hairline
        // border so the card separates from the desktop behind it. Both adapt to light/dark.
        layer?.borderWidth = 1
        setupScrim()
        setupControls()
        applyAppearanceColors()
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
        // top (clear) and end at the bottom (dark). Colors are set in `applyAppearanceColors`.
        scrim.startPoint = CGPoint(x: 0.5, y: 1)
        scrim.endPoint = CGPoint(x: 0.5, y: 0)
        scrim.locations = [0.45, 1.0]
        scrim.cornerRadius = corner
        scrim.cornerCurve = .continuous
        layer?.addSublayer(scrim)
    }

    /// (Re)applies the appearance-dependent layer colors. Must run on every effective-appearance
    /// change because a CALayer's `cgColor` is captured at assignment time and won't auto-adapt.
    private func applyAppearanceColors() {
        layer?.backgroundColor = GlassTokens.cg(GlassTokens.cardBacking, for: self)
        layer?.borderColor = GlassTokens.cg(GlassTokens.hairline, for: self)
        scrim.colors = [NSColor.clear.cgColor, GlassTokens.cg(GlassTokens.scrimBottom, for: self)]
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func setupControls() {
        let edit = makeIconButton("pencil.tip.crop.circle", "Edit (⌘E)", #selector(editTapped))
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

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.contentView.addSubview(stack)
        addSubview(toolbar)

        // Fixed glass-pill size (5 × 28pt buttons + 4 × 6pt gaps + insets). A fixed size — rather than
        // tying the glass view to the stack — avoids a layout-recursion loop with NSGlassEffectView
        // re-laying out its contentView.
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: toolbar.contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: toolbar.contentView.centerYAnchor),
            toolbar.widthAnchor.constraint(equalToConstant: 180),
            toolbar.heightAnchor.constraint(equalToConstant: 38),
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        let close = GlassIconButton.make(symbol: "xmark", tooltip: "Dismiss (⌘W)",
                                         target: self, action: #selector(closeTapped),
                                         pointSize: 10, standalone: true)
        close.translatesAutoresizingMaskIntoConstraints = false
        closeButton = close
        addSubview(close)
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    private func makeIconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .labelColor
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

    /// Brief in-card confirmation when the capture is copied — a centered "Copied" pill that fades.
    func showCopyFeedback() {
        copyBadge?.removeFromSuperview()

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = GlassTokens.Fixed.dimensionPill.cgColor
        pill.layer?.cornerRadius = 13
        pill.layer?.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        icon.contentTintColor = .white
        let label = NSTextField(labelWithString: "Copied")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        pill.addSubview(stack)
        addSubview(pill)
        copyBadge = pill

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -6),
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        pill.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            pill.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak pill, weak self] in
            guard let pill, self?.copyBadge === pill else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                pill.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { pill.removeFromSuperview() } })
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
        let item: NSDraggingItem
        // Prefer the real saved file — a plain file URL drops into Finder, text inputs, image wells,
        // and chat apps alike. A file promise (the fallback for unsaved cards) is accepted by far
        // fewer targets.
        if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) {
            item = NSDraggingItem(pasteboardWriter: savedURL as NSURL)
        } else {
            guard let png = ImageEncoder.encode(image.cgImage, as: .png) else { return }
            let filename = FilenameTemplate.render(
                Preferences.filenameTemplate, mode: mode, format: .png, counter: 0
            )
            let delegate = ImageFilePromiseDelegate(pngData: png, filename: filename)
            activePromiseDelegate = delegate
            let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: delegate)
            item = NSDraggingItem(pasteboardWriter: provider)
        }
        let fit = Self.aspectFit(imageSize: image.pixelSize, in: bounds)
        item.setDraggingFrame(fit, contents: thumbnail)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
