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
    /// Width follows the user's Quick Access size preference (Small…Extra Large); the tile stays a
    /// fixed 16:9 so the bottom-right stack reads as a uniform column at any size.
    static var cardWidth: CGFloat { Preferences.quickAccessSize.cardWidth }
    static var cardHeight: CGFloat { (cardWidth * 9 / 16).rounded() }
    static var cardSize: NSSize { NSSize(width: cardWidth, height: cardHeight) }

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
    var onUpload: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private var dragOrigin: CGPoint?
    /// Temp PNG materialized for a drag when there is no saved file; removed when the drag ends.
    private var draggedTempURL: URL?
    private var trackingArea: NSTrackingArea?
    private let thumbnail: NSImage

    private let scrim = CALayer()
    private var hoverControls: [NSView] = []
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

    /// A full-card dim so the centered Copy/Save pills and corner icons stay legible over bright
    /// screenshots. Only visible on hover. Color set in `applyAppearanceColors`.
    private func setupScrim() {
        scrim.cornerRadius = corner
        scrim.cornerCurve = .continuous
        layer?.addSublayer(scrim)
    }

    /// (Re)applies the appearance-dependent layer colors. Must run on every effective-appearance
    /// change because a CALayer's `cgColor` is captured at assignment time and won't auto-adapt.
    private func applyAppearanceColors() {
        layer?.backgroundColor = GlassTokens.cg(GlassTokens.cardBacking, for: self)
        layer?.borderColor = GlassTokens.cg(GlassTokens.hairline, for: self)
        scrim.backgroundColor = GlassTokens.cg(GlassTokens.scrimBottom, for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    /// Hover chrome, CleanShot-style quick access: two prominent capsule buttons (Copy + Save/Reveal)
    /// centered on the dimmed card, plus four corner icon buttons — pin (top-left), dismiss
    /// (top-right), edit (bottom-left), and upload-or-share (bottom-right).
    private func setupControls() {
        let copy = makeTextButton("Copy", action: #selector(copyTapped))
        let secondary = (savedURL != nil)
            ? makeTextButton("Reveal", action: #selector(revealTapped))
            : makeTextButton("Save", action: #selector(saveTapped))
        let center = NSStackView(views: [copy, secondary])
        center.orientation = .vertical
        center.spacing = 8
        center.alignment = .centerX
        center.translatesAutoresizingMaskIntoConstraints = false
        addSubview(center)
        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let pin = cornerButton("pin", "Pin to Screen", #selector(pinTapped))
        let close = cornerButton("xmark", "Dismiss (⌘W)", #selector(closeTapped))
        let edit = cornerButton("pencil.tip.crop.circle", "Edit (⌘E)", #selector(editTapped))
        let trailingBottom = CloudUploadService.isEnabled
            ? cornerButton("icloud.and.arrow.up", "Upload & Copy Link", #selector(uploadTapped))
            : cornerButton("square.and.arrow.up", "Share", #selector(shareTapped))

        for b in [pin, close, edit, trailingBottom] { addSubview(b) }
        NSLayoutConstraint.activate([
            pin.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pin.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            edit.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            edit.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            trailingBottom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingBottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        hoverControls = [center, pin, close, edit, trailingBottom]
    }

    /// A 24pt circular glass icon button (corner chrome).
    private func cornerButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSView {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(GlassTokens.symbol(11)) ?? NSImage(), target: self, action: action)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .smallSquare
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return glassHost(button, cornerRadius: 12, size: NSSize(width: 24, height: 24))
    }

    /// A glass capsule with a bold label — the prominent primary/secondary actions, same Liquid Glass
    /// material as the corner icons, fully pill-rounded.
    private func makeTextButton(_ title: String, action: Selector) -> NSView {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .labelColor
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        button.setAccessibilityLabel(title)
        // Pill hugs its label (+ side padding) so it fits both short words and longer translations,
        // with a floor so a single-glyph title still reads as a tappable capsule.
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let width = max(72, (textWidth + 32).rounded(.up))
        return glassHost(button, cornerRadius: 15, size: NSSize(width: width, height: 30))
    }

    /// Wraps a borderless button in a fixed-size `GlassPanelView` at an explicit corner radius, so the
    /// shape is a true circle (radius = half-size) or pill regardless of the system's default bezel.
    private func glassHost(_ button: NSButton, cornerRadius: CGFloat, size: NSSize) -> NSView {
        let host = GlassPanelView(cornerRadius: cornerRadius)
        button.translatesAutoresizingMaskIntoConstraints = false
        host.contentView.addSubview(button)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: host.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: host.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: host.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: host.contentView.bottomAnchor),
            host.widthAnchor.constraint(equalToConstant: size.width),
            host.heightAnchor.constraint(equalToConstant: size.height),
        ])
        return host
    }

    private func setControls(visible: Bool, animated: Bool) {
        guard visible != controlsVisible || !animated else { return }
        controlsVisible = visible
        if visible {
            scrim.isHidden = false
            hoverControls.forEach { $0.isHidden = false }
        }
        let apply = {
            self.scrim.opacity = visible ? 1 : 0
            self.hoverControls.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                apply()
            }, completionHandler: {
                MainActor.assumeIsolated {
                    // Re-check: a fresh hover may have re-shown the controls during the fade.
                    if !visible, !self.controlsVisible {
                        self.scrim.isHidden = true
                        self.hoverControls.forEach { $0.isHidden = true }
                    }
                }
            })
        } else {
            scrim.opacity = visible ? 1 : 0
            scrim.isHidden = !visible
            hoverControls.forEach {
                $0.alphaValue = visible ? 1 : 0
                $0.isHidden = !visible
            }
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
    @objc private func uploadTapped() { onUpload?() }
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
        // A file URL alone makes some targets paste the *path* text instead of the picture. Carry a
        // real file (the saved one, else a temp PNG for save-to-disk-off cards) AND the raw bytes,
        // so file-oriented targets take the file while image wells embed the actual image.
        let fileURL: URL
        if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) {
            fileURL = savedURL
        } else if let tempURL = writeTempFileForDrag(png: png) {
            fileURL = tempURL
        } else {
            return
        }
        let item = NSDraggingItem(pasteboardWriter: DragImageProvider(url: fileURL, pngData: png))
        let fit = Self.aspectFit(imageSize: image.pixelSize, in: bounds)
        item.setDraggingFrame(fit, contents: thumbnail)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// Writes the capture's PNG into a unique temp directory and returns its URL, so an unsaved
    /// card can still be dragged out as a real file. Returns nil on write failure.
    ///
    /// The temp file is deliberately NOT deleted when the drag ends: some targets (browsers, chat
    /// uploads) read the file asynchronously after the session, and deleting it mid-read makes them
    /// fall back to pasting the path. Instead we sweep the previous drag's temp dir on the next drag,
    /// which bounds the leak to one file; the OS clears the temp dir on top of that.
    private func writeTempFileForDrag(png: Data) -> URL? {
        if let prev = draggedTempURL {
            try? FileManager.default.removeItem(at: prev.deletingLastPathComponent())
            draggedTempURL = nil
        }
        let filename = FilenameTemplate.render(
            Preferences.filenameTemplate, mode: mode, format: .png, counter: 0
        )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterShutterDrag-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        draggedTempURL = url
        return url
    }
}
