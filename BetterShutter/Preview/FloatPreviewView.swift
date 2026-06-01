import AppKit
import UniformTypeIdentifiers

/// The post-capture quick-access card: a rounded thumbnail you can drag out as a PNG file, plus
/// Copy / Save / Close actions. Drawn directly (no NSImageView) so the whole thumbnail is a drag
/// handle.
@MainActor
final class FloatPreviewView: NSView, NSDraggingSource {

    static let cardSize = NSSize(width: 260, height: 200)
    private let barHeight: CGFloat = 44
    private let corner: CGFloat = 12

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
        setupButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    private var thumbRect: CGRect {
        CGRect(x: 0, y: barHeight, width: bounds.width, height: bounds.height - barHeight)
    }

    // MARK: Buttons

    private func setupButtons() {
        let edit = makeButton(symbol: "pencil.tip.crop.circle", title: "Edit", action: #selector(editTapped))
        let copy = makeButton(symbol: "doc.on.doc", title: "Copy", action: #selector(copyTapped))
        let secondary = (savedURL != nil)
            ? makeButton(symbol: "folder", title: "Show", action: #selector(revealTapped))
            : makeButton(symbol: "arrow.down.circle", title: "Save", action: #selector(saveTapped))
        let stack = NSStackView(views: [edit, copy, secondary])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: bottomAnchor, constant: barHeight / 2),
        ])

        let close = makeButton(symbol: "xmark", title: nil, action: #selector(closeTapped))
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    private func makeButton(symbol: String, title: String?, action: Selector) -> NSButton {
        let button = NSButton(title: title ?? "", target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
        return button
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

    override func draw(_ dirtyRect: NSRect) {
        // No solid card fill: a glass backdrop shows through the bottom bar + letterbox gaps.
        // Thumbnail, aspect-fit within the top region, on a rounded dark mat so any letterboxing
        // reads as part of the image well rather than bare glass.
        let inset = thumbRect.insetBy(dx: 6, dy: 6)
        let fit = Self.aspectFit(imageSize: image.pixelSize, in: inset)
        let mat = NSBezierPath(roundedRect: fit.insetBy(dx: -1, dy: -1), xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.25).setFill()
        mat.fill()
        NSGraphicsContext.current?.cgContext.interpolationQuality = .high
        let clip = NSBezierPath(roundedRect: fit, xRadius: 6, yRadius: 6)
        NSGraphicsContext.current?.saveGraphicsState()
        clip.addClip()
        thumbnail.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.restoreGraphicsState()

        // Bottom bar separator.
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: 0, y: barHeight))
        line.line(to: CGPoint(x: bounds.width, y: barHeight))
        line.stroke()
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

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    // MARK: Drag-out

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, thumbRect.contains(p) {
            dragOrigin = nil
            onAnnotate?()
            return
        }
        dragOrigin = thumbRect.contains(p) ? p : nil
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
        let fit = Self.aspectFit(imageSize: image.pixelSize, in: thumbRect.insetBy(dx: 6, dy: 6))
        item.setDraggingFrame(fit, contents: thumbnail)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
