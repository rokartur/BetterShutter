import AppKit
import BetterShortcuts
import CoreImage

/// The editor canvas. Displays the capture aspect-fit and lets the user create, select, move, and
/// delete annotation elements. Works in image-pixel space (bottom-left) so element geometry maps
/// 1:1 to the exported bitmap.
@MainActor
final class EditorCanvasView: NSView, NSTextFieldDelegate {

    private var baseImage: CGImage
    private var imageSize: CGSize
    private let ciContext = CIContext()

    /// Non-destructive photo adjustments layered over `baseImage` for display and export.
    private var adjust = ImageAdjustments()
    private var adjustedCache: CGImage?
    private var adjustGesturePending: EditorSnapshot?

    /// The base bitmap with live adjustments applied (cached); falls back to `baseImage` when neutral.
    private var renderBase: CGImage {
        if adjust.isIdentity { return baseImage }
        if let cached = adjustedCache { return cached }
        let result = adjust.apply(to: baseImage, ciContext: ciContext)
        adjustedCache = result
        return result
    }

    var currentAdjustments: ImageAdjustments { adjust }

    private(set) var elements: [AnnotationElement] = []
    private var selected: AnnotationElement?
    /// Elements captured by an area (marquee) drag. Empty for single/no selection; a single hit goes
    /// into `selected` instead so all the per-element edits (resize, rotate, restyle) keep working.
    private var groupSelection: [AnnotationElement] = []
    private var marqueeRect: CGRect?     // image space, live during a marquee drag
    private var marqueeAnchor: CGPoint?
    private var creating: AnnotationElement?
    private var stepCounter = 1

    var tool: ToolKind = .arrow {
        didSet {
            if tool != .select { selected = nil; groupSelection = []; needsDisplay = true }
            if tool == .highlighter { ensureTextLines() }
        }
    }
    var style: AnnotationStyle

    /// OCR text-line boxes in image-pixel space (bottom-left), for the smart highlighter. Populated
    /// lazily the first time the highlighter is used; empty until then (highlight stays freehand).
    private var textLines: [CGRect] = []
    private var ocrStarted = false

    /// Fired when a single-key shortcut changes the tool, so the toolbar selection can follow.
    var onToolPicked: ((ToolKind) -> Void)?
    /// Fired when the eyedropper samples a color, so the color well can follow.
    var onColorPicked: ((NSColor) -> Void)?
    /// Fired on ⌘P to print the flattened result.
    var onPrint: (() -> Void)?

    private enum DragMode { case none, creating, moving, resizing, cropping, marquee }
    private var dragMode: DragMode = .none
    private var lastImagePoint: CGPoint = .zero
    private var didMove = false
    private var resizeHandle = 0

    private var cropRect: CGRect?
    private var cropAnchor: CGPoint?

    private var editingField: NSTextField?
    private var editingElement: TextElement?

    // MARK: Undo
    //
    // Undo works on whole-document snapshots: a snapshot deep-copies every element (via `clone()`)
    // plus the crop rect, so a single uniform mechanism covers create / delete / move / restyle /
    // text / step / crop without per-operation bookkeeping. `pending` is captured at the start of a
    // gesture (before any mutation) and registered only if the gesture actually changed something.
    private let undoMgr: UndoManager = {
        let mgr = UndoManager()
        // Non-destructive ops share the base via one `UndoBaseImage` box; destructive ops
        // (rotate/flip/invert/filter) create a new box, and boxes past the recent set downgrade
        // to lossless PNG (~5–15% of raw) — so even 30 destructive steps stay in the low
        // hundreds of MB instead of pinning ~1.8 GB of full-res bitmaps.
        mgr.levelsOfUndo = 30
        return mgr
    }()
    private var pending: EditorSnapshot?
    private var textPending: EditorSnapshot?

    private struct EditorSnapshot {
        let elements: [AnnotationElement]
        let cropRect: CGRect?
        let base: UndoBaseImage
        let imageSize: CGSize
        let adjust: ImageAdjustments
    }

    /// Box holding the current `baseImage` for undo snapshots. Snapshots share the box while the
    /// base is unchanged; destructive ops swap in a fresh one via `setBase`.
    private var baseBox: UndoBaseImage
    /// Most-recent-last boxes kept live (undecoded); older ones downgrade to PNG. Current + 2
    /// previous stay live so a quick undo/redo of a destructive op is instant.
    private var recentBases: [UndoBaseImage] = []

    override var undoManager: UndoManager? { undoMgr }

    private func snapshot() -> EditorSnapshot {
        EditorSnapshot(elements: elements.map { $0.clone() }, cropRect: cropRect,
                       base: baseBox, imageSize: imageSize, adjust: adjust)
    }

    /// Single choke point for destructive base replacements (rotate/flip/invert/filter).
    private func setBase(_ image: CGImage) {
        baseImage = image
        baseBox = UndoBaseImage(image)
        touchRecent(baseBox)
    }

    /// Move `box` to the end of the live set and downgrade whatever falls off the front.
    private func touchRecent(_ box: UndoBaseImage) {
        recentBases.removeAll { $0 === box }
        recentBases.append(box)
        while recentBases.count > 3 {
            recentBases.removeFirst().downgrade()
        }
    }

    /// The redaction elements' interactive caches self-invalidate by key, but when the base bitmap
    /// is replaced this frees the old ~full-res sources they reference without waiting for the
    /// next repaint of each element.
    private func invalidateElementRenderCaches() {
        for element in elements { element.invalidateRenderCache() }
    }

    /// Register `before` as the state to return to, naming the action for the Edit menu.
    private func commit(_ before: EditorSnapshot?, _ name: String) {
        guard let before else { return }
        undoMgr.registerUndo(withTarget: self) { $0.restore(before, name) }
        undoMgr.setActionName(name)
    }

    /// Swap the document to `snap`, registering the inverse so redo (and further undo) works.
    private func restore(_ snap: EditorSnapshot, _ name: String) {
        finishTextEditing()
        guard let restoredBase = snap.base.image else { return }   // decode failure: keep current state
        let inverse = snapshot()
        undoMgr.registerUndo(withTarget: self) { $0.restore(inverse, name) }
        undoMgr.setActionName(name)
        elements = snap.elements
        cropRect = snap.cropRect
        baseImage = restoredBase
        baseBox = snap.base
        touchRecent(snap.base)
        imageSize = snap.imageSize
        adjust = snap.adjust
        adjustedCache = nil
        invalidateElementRenderCaches()
        adjustGesturePending = nil
        selected = nil
        groupSelection = []
        marqueeRect = nil
        creating = nil
        dragMode = .none
        zoomFactor = 1
        panOffset = .zero
        needsDisplay = true
    }

    // MARK: Whole-canvas transforms

    func applyImageTransform(_ kind: ImageTransform) {
        guard let newBase = ImageTransformer.apply(kind, to: baseImage) else { return }
        let (t, newSize) = ImageTransformer.affine(kind, width: imageSize.width, height: imageSize.height)
        let before = snapshot()
        setBase(newBase)
        imageSize = newSize
        adjustedCache = nil
        invalidateElementRenderCaches()
        for element in elements { element.transform(t) }
        if let crop = cropRect { cropRect = crop.applying(t) }
        selected = nil
        groupSelection = []
        commit(before, kind.actionName)
        needsDisplay = true
    }

    func invertColors() {
        guard let inverted = ImageTransformer.inverted(baseImage) else { return }
        let before = snapshot()
        setBase(inverted)
        adjustedCache = nil
        invalidateElementRenderCaches()
        commit(before, "Invert Colors")
        needsDisplay = true
    }

    /// Apply non-destructive photo adjustments live. `doCommit` registers one undo step at the end
    /// of a slider drag (caller passes true on mouse-up), coalescing the whole drag into one action.
    func setAdjustments(_ adjustments: ImageAdjustments, commit doCommit: Bool) {
        if adjustGesturePending == nil { adjustGesturePending = snapshot() }
        adjust = adjustments
        adjustedCache = nil
        invalidateElementRenderCaches()
        needsDisplay = true
        if doCommit {
            commit(adjustGesturePending, "Adjust")
            adjustGesturePending = nil
        }
    }

    func resetAdjustments() { setAdjustments(ImageAdjustments(), commit: true) }

    /// Formatting applied to new text; mirrors the toolbar's rich-text toggles.
    private var textFormatDefault = TextFormatting()

    /// Apply rich-text formatting to the selected (or in-progress) text element and remember it as
    /// the default for new text. One undo step for a committed element.
    func setTextFormatting(_ fmt: TextFormatting) {
        textFormatDefault = fmt
        if let editingElement {
            editingElement.format = fmt
            needsDisplay = true
        } else if let text = selected as? TextElement {
            let before = snapshot()
            text.format = fmt
            commit(before, "Text Style")
            needsDisplay = true
        }
    }

    /// Add another image onto the canvas, centered and scaled to fit, selected for repositioning.
    func addComposedImage(_ cg: CGImage) {
        let before = snapshot()
        let scale = min(imageSize.width * 0.5 / CGFloat(cg.width), imageSize.height * 0.5 / CGFloat(cg.height), 1)
        let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
        let frame = CGRect(x: imageSize.width / 2 - w / 2, y: imageSize.height / 2 - h / 2, width: w, height: h)
        let element = ImageElement(image: cg, frame: frame, style: style)
        elements.append(element)
        groupSelection = []
        selected = element
        tool = .select
        onToolPicked?(.select)
        commit(before, "Add Image")
        needsDisplay = true
    }

    /// Prompt for watermark text and add it (tiled diagonally across the image by default), one undo.
    func addWatermark() {
        let alert = NSAlert()
        alert.messageText = "Add Watermark"
        alert.informativeText = "Overlay text across the image."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        field.placeholderString = "Confidential"
        let tile = NSButton(checkboxWithTitle: "Tile across image", target: nil, action: nil)
        tile.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        tile.state = .on
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        accessory.addSubview(field)
        accessory.addSubview(tile)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let before = snapshot()
        let tiled = tile.state == .on
        let anchor = tiled ? .zero : CGPoint(x: imageSize.width * 0.06, y: imageSize.height * 0.06)
        let element = WatermarkElement(text: text, tiled: tiled, anchor: anchor,
                                       imageSize: imageSize, style: style)
        elements.append(element)
        selected = element
        commit(before, "Watermark")
        needsDisplay = true
    }

    /// Detect faces and blur each one (one undo step) — privacy redaction for people in a shot.
    func autoRedactFaces() {
        let image = CapturedImage(cgImage: baseImage, scale: 1, displayID: nil)
        let size = imageSize
        let currentStyle = style
        Task { [weak self] in
            let faces = await FaceDetector.detect(image)
            guard let self else { return }
            guard !faces.isEmpty else { HUD.show("No faces found"); return }
            let before = snapshot()
            for box in faces {
                // Vision box is normalized bottom-left → image-pixel bottom-left, padded to the head.
                let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                                  width: box.width * size.width, height: box.height * size.height)
                    .insetBy(dx: -box.width * size.width * 0.12, dy: -box.height * size.height * 0.12)
                let blur = BlurElement(start: CGPoint(x: rect.minX, y: rect.minY), style: currentStyle)
                blur.end = CGPoint(x: rect.maxX, y: rect.maxY)
                blur.style.redactionStrength = 0.9
                elements.append(blur)
            }
            commit(before, "Redact Faces")
            HUD.show("Redacted \(faces.count) face\(faces.count == 1 ? "" : "s")")
            needsDisplay = true
        }
    }

    /// Find PII via OCR and cover each matching line with a black-out box (one undo step).
    func autoRedactPII() {
        let image = CapturedImage(cgImage: baseImage, scale: 1, displayID: nil)
        let size = imageSize
        let currentStyle = style
        Task { [weak self] in
            let observations = await TextRecognizer.observations(image)
            let matches = observations.filter { PIIMatcher.containsPII($0.text) }
            guard let self else { return }
            guard !matches.isEmpty else { HUD.show("No PII found"); return }
            let before = snapshot()
            for match in matches {
                // Vision box is normalized bottom-left → scale to image-pixel bottom-left space.
                let rect = CGRect(x: match.box.minX * size.width, y: match.box.minY * size.height,
                                  width: match.box.width * size.width, height: match.box.height * size.height)
                let block = BlackoutElement(start: CGPoint(x: rect.minX, y: rect.minY), style: currentStyle)
                block.end = CGPoint(x: rect.maxX, y: rect.maxY)
                elements.append(block)
            }
            commit(before, "Auto-Redact")
            HUD.show("Redacted \(matches.count)")
            needsDisplay = true
        }
    }

    /// Apply a Core Image photo-effect filter destructively to the base image (undoable).
    func applyFilter(named name: String) {
        let source = CIImage(cgImage: baseImage)
        guard let filter = CIFilter(name: name) else { return }
        filter.setValue(source, forKey: kCIInputImageKey)
        guard let output = filter.outputImage,
              let cg = ciContext.createCGImage(output, from: source.extent) else { return }
        let before = snapshot()
        setBase(cg)
        adjustedCache = nil
        invalidateElementRenderCaches()
        commit(before, "Filter")
        needsDisplay = true
    }

    /// Run OCR once over the current base image and cache line boxes (converted from Vision's
    /// normalized bottom-left space to image pixels) for the smart highlighter. Non-blocking.
    private func ensureTextLines() {
        guard !ocrStarted else { return }
        ocrStarted = true
        let image = CapturedImage(cgImage: baseImage, scale: 1, displayID: nil)
        let size = imageSize
        Task { [weak self] in
            let observations = await TextRecognizer.observations(image)
            guard let self else { return }
            self.textLines = observations.map { o in
                CGRect(x: o.box.minX * size.width, y: o.box.minY * size.height,
                       width: o.box.width * size.width, height: o.box.height * size.height)
            }
        }
    }

    init(image: CapturedImage, elements: [AnnotationElement] = []) {
        self.baseImage = image.cgImage
        self.baseBox = UndoBaseImage(image.cgImage)
        self.imageSize = image.pixelSize
        self.style = AnnotationStyle.makeDefault(imageWidth: image.pixelSize.width)
        super.init(frame: NSRect(origin: .zero, size: Self.fittedSize(for: image.pixelSize)))
        self.recentBases = [baseBox]
        self.elements = elements
        // Resume step numbering past any restored badges so new ones don't collide.
        self.stepCounter = (elements.compactMap { ($0 as? StepElement)?.number }.max() ?? 0) + 1
        wantsLayer = true
    }

    /// The unflattened base bitmap, for saving a re-editable project.
    var baseCGImage: CGImage { baseImage }

    /// Annotation layers for a project save, after committing any in-progress text edit.
    func projectElements() -> [AnnotationElement] {
        finishTextEditing()
        return elements
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    /// A reasonable initial editor size for an image, capped to a sensible on-screen box.
    static func fittedSize(for pixelSize: CGSize) -> NSSize {
        let maxBox = CGSize(width: 1100, height: 750)
        let scale = min(maxBox.width / pixelSize.width, maxBox.height / pixelSize.height, 1)
        return NSSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }

    /// Zoom relative to the aspect-fit baseline: 1 = fit-to-window, up to `maxZoom` zoomed in.
    private var zoomFactor: CGFloat = 1
    /// Pan in view points while zoomed in; always 0 at fit.
    private var panOffset: CGSize = .zero
    private let maxZoom: CGFloat = 16
    var isZoomed: Bool { zoomFactor > 1.0001 }

    /// The scale that fits the whole image into the inset bounds (zoom 1).
    private var fitScale: CGFloat {
        let inset = bounds.insetBy(dx: 16, dy: 16)
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(inset.width / imageSize.width, inset.height / imageSize.height)
    }

    private var displayRect: CGRect {
        let inset = bounds.insetBy(dx: 16, dy: 16)
        guard imageSize.width > 0, imageSize.height > 0 else { return inset }
        let s = fitScale * zoomFactor
        let size = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        return CGRect(x: inset.midX - size.width / 2 + panOffset.width,
                      y: inset.midY - size.height / 2 + panOffset.height,
                      width: size.width, height: size.height)
    }

    private var scale: CGFloat { displayRect.width / max(imageSize.width, 1) }

    private func imagePoint(_ p: CGPoint) -> CGPoint {
        let u = imagePointUnclamped(p)
        return CGPoint(x: min(max(0, u.x), imageSize.width), y: min(max(0, u.y), imageSize.height))
    }

    /// Image-space point without clamping to the bitmap, so zoom-around-cursor tracks points that
    /// momentarily fall outside the image.
    private func imagePointUnclamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - displayRect.minX) / scale, y: (p.y - displayRect.minY) / scale)
    }

    private func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: displayRect.minX + p.x * scale, y: displayRect.minY + p.y * scale)
    }

    // MARK: Zoom & pan

    /// Set the zoom (clamped to 1…maxZoom), keeping the image point under `pivot` (view coords) fixed.
    private func setZoom(_ newZoom: CGFloat, around pivot: CGPoint) {
        let clamped = min(max(newZoom, 1), maxZoom)
        guard abs(clamped - zoomFactor) > 0.0001 else { return }
        let imgPt = imagePointUnclamped(pivot)
        zoomFactor = clamped
        if clamped <= 1.0001 {
            panOffset = .zero
        } else {
            let landed = viewPoint(imgPt)   // where that image point is now, before re-panning
            panOffset.width += pivot.x - landed.x
            panOffset.height += pivot.y - landed.y
            clampPan()
        }
        needsDisplay = true
    }

    /// Keep the (possibly zoomed) image from being dragged entirely out of the inset.
    private func clampPan() {
        let inset = bounds.insetBy(dx: 16, dy: 16)
        let s = fitScale * zoomFactor
        let size = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        func clamp(_ offset: CGFloat, _ imgExtent: CGFloat, _ box: CGFloat) -> CGFloat {
            guard imgExtent > box else { return 0 }    // smaller than the box → stay centered
            let maxOff = (imgExtent - box) / 2
            return min(max(offset, -maxOff), maxOff)
        }
        panOffset.width = clamp(panOffset.width, size.width, inset.width)
        panOffset.height = clamp(panOffset.height, size.height, inset.height)
    }

    func zoomIn() { setZoom(zoomFactor * 1.25, around: CGPoint(x: bounds.midX, y: bounds.midY)) }
    func zoomOut() { setZoom(zoomFactor / 1.25, around: CGPoint(x: bounds.midX, y: bounds.midY)) }
    func zoomToFit() { zoomFactor = 1; panOffset = .zero; needsDisplay = true }

    override func magnify(with event: NSEvent) {
        let pivot = convert(event.locationInWindow, from: nil)
        setZoom(zoomFactor * (1 + event.magnification), around: pivot)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isZoomed else { super.scrollWheel(with: event); return }
        panOffset.width += event.scrollingDeltaX
        panOffset.height += event.scrollingDeltaY
        clampPan()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        dirtyRect.fill()

        let display = renderBase
        cg.saveGState()
        cg.clip(to: dirtyRect)
        cg.draw(display, in: displayRect)
        cg.restoreGState()

        cg.saveGState()
        cg.translateBy(x: displayRect.minX, y: displayRect.minY)
        cg.scaleBy(x: scale, y: scale)
        let rc = AnnotationRenderContext(baseImage: display, imageSize: imageSize,
                                         ciContext: ciContext, isInteractive: true)
        // Cull to the invalidated area — targeted invalidations (drags, nudges) then pay only for
        // the elements they touched, not a full re-render of every annotation.
        for element in elements where invalidationRect(for: element).intersects(dirtyRect) {
            element.drawRotated(in: cg, context: rc)
        }
        cg.restoreGState()

        if let selected, selected !== editingElement,
           invalidationRect(for: selected).intersects(dirtyRect) {
            drawSelectionHandles(for: selected)
        }
        for el in groupSelection
        where el !== editingElement && invalidationRect(for: el).intersects(dirtyRect) {
            drawSelectionOutline(for: el)
        }
        if let marqueeRect { drawMarquee(marqueeRect) }
        if let cropRect { drawCropOverlay(cropRect) }
    }

    /// View-space rect to invalidate when `element` changes: painted area plus selection chrome
    /// (8 pt handle squares straddle the outline) and antialiasing slop.
    private func invalidationRect(for element: AnnotationElement) -> CGRect {
        var box = element.paintBounds
        guard !box.isInfinite else { return bounds }
        if element.rotation != 0 { box = box.applying(element.rotationTransform) }
        let origin = viewPoint(box.origin)
        return CGRect(x: origin.x, y: origin.y, width: box.width * scale, height: box.height * scale)
            .insetBy(dx: -14, dy: -14)
    }

    private func invalidationRect(of targets: [AnnotationElement]) -> CGRect {
        targets.reduce(CGRect.null) { $0.union(invalidationRect(for: $1)) }
    }

    private func viewRect(forImageRect r: CGRect) -> CGRect {
        CGRect(origin: viewPoint(r.origin),
               size: CGSize(width: r.width * scale, height: r.height * scale))
    }

    /// Translucent rectangle drawn while dragging an area (marquee) selection.
    private func drawMarquee(_ imageRect: CGRect) {
        let r = CGRect(origin: viewPoint(imageRect.origin),
                       size: CGSize(width: imageRect.width * scale, height: imageRect.height * scale))
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: r).fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        border.stroke()
    }

    private func drawCropOverlay(_ imageRect: CGRect) {
        let r = CGRect(origin: viewPoint(imageRect.origin),
                       size: CGSize(width: imageRect.width * scale, height: imageRect.height * scale))
        let area = displayRect
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: NSRect(x: area.minX, y: r.maxY, width: area.width, height: area.maxY - r.maxY)).fill()
        NSBezierPath(rect: NSRect(x: area.minX, y: area.minY, width: area.width, height: r.minY - area.minY)).fill()
        NSBezierPath(rect: NSRect(x: area.minX, y: r.minY, width: r.minX - area.minX, height: r.height)).fill()
        NSBezierPath(rect: NSRect(x: r.maxX, y: r.minY, width: area.maxX - r.maxX, height: r.height)).fill()
        // Rule-of-thirds guides inside the crop rect.
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let thirds = NSBezierPath()
        thirds.lineWidth = 0.5
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3
            let y = r.minY + r.height * CGFloat(i) / 3
            thirds.move(to: CGPoint(x: x, y: r.minY)); thirds.line(to: CGPoint(x: x, y: r.maxY))
            thirds.move(to: CGPoint(x: r.minX, y: y)); thirds.line(to: CGPoint(x: r.maxX, y: y))
        }
        thirds.stroke()

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1.5
        border.stroke()
    }

    /// Dashed bounding box that follows the element's rotation. Shared by single and group selection.
    private func drawSelectionOutline(for element: AnnotationElement) {
        let box = element.boundingBox
        let t = element.rotationTransform
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
        ].map { viewPoint(element.rotation == 0 ? $0 : $0.applying(t)) }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.move(to: corners[0])
        for c in corners.dropFirst() { path.line(to: c) }
        path.close()
        path.stroke()
    }

    private func drawSelectionHandles(for element: AnnotationElement) {
        let t = element.rotationTransform
        drawSelectionOutline(for: element)

        // Grab squares at each resize handle.
        for hp in element.handlePoints() {
            let v = viewPoint(element.rotation == 0 ? hp : hp.applying(t))
            let square = NSBezierPath(roundedRect: CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8),
                                      xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            square.fill()
            square.lineWidth = 1
            square.setLineDash([], count: 0, phase: 0)
            NSColor.controlAccentColor.setStroke()
            square.stroke()
        }
    }

    /// Index of the resize handle of `element` near `viewPt` (view coords), or nil.
    private func handleIndex(at viewPt: CGPoint, of element: AnnotationElement) -> Int? {
        let t = element.rotationTransform
        for (i, hp) in element.handlePoints().enumerated() {
            let v = viewPoint(element.rotation == 0 ? hp : hp.applying(t))
            if hypot(v.x - viewPt.x, v.y - viewPt.y) <= 8 { return i }
        }
        return nil
    }

    // MARK: Mouse

    /// Capture the pre-gesture snapshot lazily, only once a mutation actually begins — an empty
    /// click or pure selection shouldn't deep-clone every element on the canvas.
    private func ensurePending() {
        if pending == nil { pending = snapshot() }
    }

    override func mouseDown(with event: NSEvent) {
        finishTextEditing()
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        lastImagePoint = p
        didMove = false

        switch tool {
        case .select:
            // A grabbed handle of the current selection takes priority over re-selecting.
            if let sel = selected,
               let hi = handleIndex(at: convert(event.locationInWindow, from: nil), of: sel) {
                resizeHandle = hi
                dragMode = .resizing
                if sel.rotation != 0 { sel.resizePivot = sel.rotationCenter }  // pin pivot for the gesture
            } else if let hit = elements.last(where: { $0.hitTest($0.localPoint(p)) }) {
                if groupSelection.contains(where: { $0 === hit }) {
                    dragMode = .moving   // grab anywhere inside a marquee group to move it as one
                } else {
                    groupSelection = []
                    selected = hit
                    dragMode = .moving
                }
            } else {
                // Empty space → start an area (marquee) selection.
                selected = nil
                groupSelection = []
                marqueeAnchor = p
                marqueeRect = nil
                dragMode = .marquee
            }
        case .text:
            beginText(at: p)
        case .step:
            pending = snapshot()
            let element = StepElement(center: p, number: stepCounter, style: style,
                                      format: Preferences.stepFormat, start: Preferences.stepStart)
            stepCounter += 1
            elements.append(element)
            selected = element
            dragMode = .none
            commit(pending, "Add Step")
            pending = nil
        case .stamp:
            presentStampMenu(with: event, at: p)
            dragMode = .none
        case .eyedropper:
            // PixelSampler uses top-left origin; canvas points are bottom-left.
            if let rgb = PixelSampler.rgb(in: baseImage, x: Int(p.x), y: Int(imageSize.height - p.y)) {
                let color = NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                                    blue: CGFloat(rgb.b) / 255, alpha: 1)
                style.color = color
                onColorPicked?(color)
            }
            dragMode = .none
        case .crop:
            // Captured eagerly: a lazy snapshot in mouseDragged would record cropRect already
            // nil-ed below, so undoing a re-crop would lose the previous crop.
            pending = snapshot()
            cropAnchor = p
            cropRect = nil
            dragMode = .cropping
        default:
            pending = snapshot()
            let element = makeDragElement(at: p)
            elements.append(element)
            creating = element
            dragMode = .creating
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        // Each mode invalidates only the union of the affected elements' before/after rects; the
        // rest of the canvas keeps its backing store instead of re-rendering per mouse event.
        switch dragMode {
        case .creating:
            guard let creating else { return }
            let before = invalidationRect(for: creating)
            var target = p
            // Shift constrains directional tools to 45° increments.
            if event.modifierFlags.contains(.shift), [.line, .arrow, .measure].contains(tool),
               let twoPoint = creating as? TwoPointElement {
                target = AngleSnap.snap(start: twoPoint.start, end: p)
            }
            creating.updateDrag(to: target)
            setNeedsDisplay(before.union(invalidationRect(for: creating)))
        case .moving:
            ensurePending()
            let targets = groupSelection.isEmpty ? [selected].compactMap { $0 } : groupSelection
            let before = invalidationRect(of: targets)
            let delta = CGSize(width: p.x - lastImagePoint.x, height: p.y - lastImagePoint.y)
            for el in targets { el.translate(by: delta) }
            lastImagePoint = p
            if delta.width != 0 || delta.height != 0 { didMove = true }
            setNeedsDisplay(before.union(invalidationRect(of: targets)))
        case .marquee:
            if let anchor = marqueeAnchor {
                let oldGroup = groupSelection
                var dirty = marqueeRect.map { viewRect(forImageRect: $0).insetBy(dx: -2, dy: -2) } ?? .null
                let r = SelectionModel.rect(from: anchor, to: p)
                marqueeRect = r
                groupSelection = elements.filter { $0.boundingBox.intersects(r) }
                dirty = dirty.union(viewRect(forImageRect: r).insetBy(dx: -2, dy: -2))
                // Dashed outlines appear/disappear as elements enter or leave the marquee.
                for el in oldGroup where !groupSelection.contains(where: { $0 === el }) {
                    dirty = dirty.union(invalidationRect(for: el))
                }
                for el in groupSelection where !oldGroup.contains(where: { $0 === el }) {
                    dirty = dirty.union(invalidationRect(for: el))
                }
                setNeedsDisplay(dirty)
            }
        case .resizing:
            guard let selected else { return }
            ensurePending()
            let before = invalidationRect(for: selected)
            selected.moveHandle(resizeHandle, to: selected.localPoint(p))
            didMove = true
            setNeedsDisplay(before.union(invalidationRect(for: selected)))
        case .cropping:
            if let anchor = cropAnchor { cropRect = SelectionModel.rect(from: anchor, to: p) }
            // The crop dim covers the whole image area (not the outer canvas margin).
            setNeedsDisplay(displayRect.insetBy(dx: -2, dy: -2))
        case .none:
            break
        }
    }

    /// If a freehand highlight overlaps OCR'd text lines, snap it to cover them (smart highlighter).
    private func snapHighlightToText(_ element: AnnotationElement) {
        guard let highlight = element as? HighlightElement, !textLines.isEmpty,
              let snapped = HighlightSnap.snap(drawn: highlight.boundingBox, lines: textLines) else { return }
        highlight.start = CGPoint(x: snapped.minX, y: snapped.minY)
        highlight.end = CGPoint(x: snapped.maxX, y: snapped.maxY)
    }

    override func mouseUp(with event: NSEvent) {
        if dragMode == .creating, let creating {
            if creating.isDegenerate, let index = elements.firstIndex(where: { $0 === creating }) {
                elements.remove(at: index)
                selected = nil
            } else {
                snapHighlightToText(creating)
                selected = creating
                commit(pending, "Add \(tool.label)")
            }
        }
        if dragMode == .moving, didMove {
            commit(pending, "Move")
        }
        if dragMode == .resizing {
            selected?.resizePivot = nil   // unpin the rotation pivot after the gesture
            if didMove { commit(pending, "Resize") }
        }
        if dragMode == .cropping {
            if let r = cropRect, r.width < 5 || r.height < 5 { cropRect = nil }
            cropAnchor = nil
            if cropRect != pending?.cropRect { commit(pending, "Crop") }
        }
        if dragMode == .marquee {
            marqueeAnchor = nil
            marqueeRect = nil
            // Collapse a one-element marquee into a normal single selection.
            if groupSelection.count == 1 { selected = groupSelection.removeFirst() }
        }
        pending = nil
        creating = nil
        dragMode = .none
        needsDisplay = true
    }

    // MARK: Style context menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let fill = NSMenuItem(title: "Fill", action: nil, keyEquivalent: "")
        let fillSub = NSMenu()
        for (title, mode) in [("Outline", FillMode.stroke), ("Outline + Fill", .strokeFill), ("Solid", .fill)] {
            let item = NSMenuItem(title: title, action: #selector(setFillMode(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue
            item.state = style.fillMode == mode ? .on : .off
            fillSub.addItem(item)
        }
        fill.submenu = fillSub
        menu.addItem(fill)

        let line = NSMenuItem(title: "Line", action: nil, keyEquivalent: "")
        let lineSub = NSMenu()
        for (title, dash) in [("Solid", DashStyle.solid), ("Dashed", .dashed), ("Dotted", .dotted)] {
            let item = NSMenuItem(title: title, action: #selector(setDash(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = dash.rawValue
            item.state = style.dash == dash ? .on : .off
            lineSub.addItem(item)
        }
        line.submenu = lineSub
        menu.addItem(line)

        let arrow = NSMenuItem(title: "Arrow", action: nil, keyEquivalent: "")
        let arrowSub = NSMenu()
        for (title, kind) in [("Straight", ArrowStyle.straight), ("Curved", .curved), ("Elbow", .elbow)] {
            let item = NSMenuItem(title: title, action: #selector(setArrowStyle(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = kind.rawValue
            item.state = style.arrowStyle == kind ? .on : .off
            arrowSub.addItem(item)
        }
        arrow.submenu = arrowSub
        menu.addItem(arrow)

        let corners = NSMenuItem(title: "Corners", action: nil, keyEquivalent: "")
        let cornersSub = NSMenu()
        for (title, value) in [("Square", CGFloat(0)), ("Small", 8), ("Medium", 16), ("Large", 28)] {
            let item = NSMenuItem(title: title, action: #selector(setCornerRadius(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value
            item.state = abs(style.cornerRadius - value) < 0.5 ? .on : .off
            cornersSub.addItem(item)
        }
        corners.submenu = cornersSub
        menu.addItem(corners)

        if selected != nil {
            let rotate = NSMenuItem(title: "Rotate", action: nil, keyEquivalent: "")
            let rotateSub = NSMenu()
            for (title, deg) in [("Left 90°", -90.0), ("Right 90°", 90.0), ("−15°", -15.0), ("+15°", 15.0)] {
                let item = NSMenuItem(title: title, action: #selector(rotateSelected(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = deg
                rotateSub.addItem(item)
            }
            rotateSub.addItem(.separator())
            let reset = NSMenuItem(title: "Reset Rotation", action: #selector(resetRotation), keyEquivalent: "")
            reset.target = self
            rotateSub.addItem(reset)
            rotate.submenu = rotateSub
            menu.addItem(rotate)
        }

        if elements.contains(where: { $0 is StepElement }) {
            let number = NSMenuItem(title: "Step Numbers", action: nil, keyEquivalent: "")
            let numberSub = NSMenu()
            for format in StepFormat.allCases {
                let item = NSMenuItem(title: format.presentableName, action: #selector(setStepFormat(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = format.rawValue
                item.state = Preferences.stepFormat == format ? .on : .off
                numberSub.addItem(item)
            }
            number.submenu = numberSub
            menu.addItem(number)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func rotateSelected(_ sender: NSMenuItem) {
        guard let selected, let deg = sender.representedObject as? Double else { return }
        let before = snapshot()
        selected.rotation += CGFloat(deg) * .pi / 180
        commit(before, "Rotate")
        needsDisplay = true
    }

    @objc private func resetRotation() {
        guard let selected else { return }
        let before = snapshot()
        selected.rotation = 0
        commit(before, "Reset Rotation")
        needsDisplay = true
    }

    @objc private func setArrowStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = ArrowStyle(rawValue: raw) else { return }
        style.arrowStyle = kind
        if let selected {
            let before = snapshot()
            selected.style.arrowStyle = kind
            commit(before, "Arrow Style")
        }
        needsDisplay = true
    }

    @objc private func setCornerRadius(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        style.cornerRadius = value
        if let selected {
            let before = snapshot()
            selected.style.cornerRadius = value
            commit(before, "Corner Radius")
        }
        needsDisplay = true
    }

    @objc private func setStepFormat(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let format = StepFormat(rawValue: raw) else { return }
        Preferences.stepFormat = format
        let steps = elements.compactMap { $0 as? StepElement }
        guard !steps.isEmpty else { return }
        let before = snapshot()
        for step in steps { step.format = format }
        commit(before, "Step Numbers")
        needsDisplay = true
    }

    @objc private func setFillMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = FillMode(rawValue: raw) else { return }
        style.fillMode = mode
        if let selected {
            let before = snapshot()
            selected.style.fillMode = mode
            commit(before, "Fill")
        }
        needsDisplay = true
    }

    @objc private func setDash(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let dash = DashStyle(rawValue: raw) else { return }
        style.dash = dash
        if let selected {
            let before = snapshot()
            selected.style.dash = dash
            commit(before, "Line Style")
        }
        needsDisplay = true
    }

    private static let stampEmojis = ["⭐️", "❤️", "✅", "❌", "🔥", "👍", "👎", "⚠️", "💡", "🎯", "😀", "🚀", "🔒", "📌", "➡️", "💬"]

    private func presentStampMenu(with event: NSEvent, at p: CGPoint) {
        let menu = NSMenu()
        for emoji in Self.stampEmojis {
            let item = NSMenuItem(title: emoji, action: #selector(placeStamp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["emoji": emoji, "x": p.x, "y": p.y] as [String: Any]
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func placeStamp(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let emoji = info["emoji"] as? String,
              let x = info["x"] as? CGFloat, let y = info["y"] as? CGFloat else { return }
        let before = snapshot()
        let stamp = StampElement(center: CGPoint(x: x, y: y), emoji: emoji, style: style)
        elements.append(stamp)
        selected = stamp
        commit(before, "Stamp")
        needsDisplay = true
    }

    private func makeDragElement(at p: CGPoint) -> AnnotationElement {
        switch tool {
        case .arrow: return ArrowElement(start: p, style: style)
        case .rectangle: return RectangleElement(start: p, style: style)
        case .ellipse: return EllipseElement(start: p, style: style)
        case .line: return LineElement(start: p, style: style)
        case .pen: return PenElement(start: p, style: style)
        case .marker: return MarkerElement(start: p, style: style)
        case .measure: return MeasureElement(start: p, style: style)
        case .loupe: return LoupeElement(center: p, style: style)
        case .highlighter: return HighlightElement(start: p, style: style)
        case .pixelate: return PixelateElement(start: p, style: style)
        case .blur: return BlurElement(start: p, style: style)
        case .blackout: return BlackoutElement(start: p, style: style)
        case .erase: return SmartEraseElement(start: p, style: style)
        case .spotlight: return SpotlightElement(start: p, style: style)
        default: return RectangleElement(start: p, style: style)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // ⌘Z / ⌘⇧Z — layout-aware via charactersIgnoringModifiers (not a fixed keyCode).
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            finishTextEditing()
            if event.modifierFlags.contains(.shift) { undoMgr.redo() } else { undoMgr.undo() }
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p" {
            onPrint?()
            return
        }
        if event.modifierFlags.contains(.command), let ch = event.charactersIgnoringModifiers {
            switch ch {
            case "=", "+": zoomIn(); return
            case "-", "_": zoomOut(); return
            case "0": zoomToFit(); return
            default: break
            }
        }
        // Tool shortcuts (single keys by default, recordable in Settings ▸ Editor). A text field,
        // when editing, is the first responder instead of the canvas, so these never fire mid-typing.
        if let shortcut = BetterShortcuts.Shortcut(event: event),
           let picked = ToolKind.forShortcut(shortcut) {
            tool = picked
            onToolPicked?(picked)
            return
        }
        switch event.keyCode {
        case 51, 117: // delete / forward-delete
            deleteSelected()
        case 53: // esc
            if editingField != nil { finishTextEditing() }
            else { selected = nil; groupSelection = []; needsDisplay = true }
        case 123, 124, 125, 126: // arrows nudge the selection
            if selected != nil || !groupSelection.isEmpty {
                nudgeSelected(keyCode: event.keyCode, large: event.modifierFlags.contains(.shift))
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// Move the selection by 1px (10px with Shift). Image space is bottom-left, so Up = +y.
    private func nudgeSelected(keyCode: UInt16, large: Bool) {
        let targets = groupSelection.isEmpty ? [selected].compactMap { $0 } : groupSelection
        guard !targets.isEmpty else { return }
        let step: CGFloat = large ? 10 : 1
        var delta = CGSize.zero
        switch keyCode {
        case 123: delta.width = -step
        case 124: delta.width = step
        case 125: delta.height = -step
        case 126: delta.height = step
        default: break
        }
        let before = snapshot()
        let dirtyBefore = invalidationRect(of: targets)
        for el in targets { el.translate(by: delta) }
        commit(before, "Nudge")
        setNeedsDisplay(dirtyBefore.union(invalidationRect(of: targets)))
    }

    func deleteSelected() {
        if !groupSelection.isEmpty {
            let before = snapshot()
            elements.removeAll { e in groupSelection.contains { $0 === e } }
            groupSelection = []
            selected = nil
            resequenceSteps()
            commit(before, "Delete")
            needsDisplay = true
            return
        }
        guard let selected, let index = elements.firstIndex(where: { $0 === selected }) else { return }
        let before = snapshot()
        elements.remove(at: index)
        self.selected = nil
        resequenceSteps()
        commit(before, "Delete")
        needsDisplay = true
    }

    /// Renumber step badges 1…n in their array order, so deleting one closes the gap.
    private func resequenceSteps() {
        var n = 1
        for case let step as StepElement in elements {
            step.number = n
            n += 1
        }
        stepCounter = n
    }

    // MARK: Text editing

    private func beginText(at p: CGPoint) {
        textPending = snapshot()   // before the empty TextElement is appended
        let element = TextElement(origin: p, text: "", style: style, format: textFormatDefault)
        elements.append(element)
        editingElement = element
        selected = element

        let field = NSTextField(frame: textFieldFrame(for: element))
        field.font = NSFont.systemFont(ofSize: style.fontSize * scale, weight: .semibold)
        field.textColor = style.color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = "Text"
        addSubview(field)
        editingField = field
        window?.makeFirstResponder(field)
    }

    private func textFieldFrame(for element: TextElement) -> CGRect {
        let v = viewPoint(element.origin)
        let h = style.fontSize * scale * 1.4
        return CGRect(x: v.x, y: v.y - h * 0.25, width: 220, height: h)
    }

    func controlTextDidEndEditing(_ obj: Notification) { finishTextEditing() }

    private func finishTextEditing() {
        guard let field = editingField, let element = editingElement else { return }
        element.text = field.stringValue
        field.removeFromSuperview()
        editingField = nil
        editingElement = nil
        if element.isDegenerate, let index = elements.firstIndex(where: { $0 === element }) {
            elements.remove(at: index)
            selected = nil
        } else {
            commit(textPending, "Add Text")
        }
        textPending = nil
        needsDisplay = true
    }

    // MARK: Style + export

    func applyColor(_ color: NSColor) {
        style.color = color
        if let selected {
            let before = snapshot()
            selected.style.color = color
            commit(before, "Color")
        }
        editingField?.textColor = color
        needsDisplay = true
    }

    func applyStrokeWidth(_ width: CGFloat) {
        style.strokeWidth = width
        if let selected {
            let before = snapshot()
            selected.style.strokeWidth = width
            commit(before, "Stroke Width")
        }
        needsDisplay = true
    }

    /// Sets the pixelate/blur redaction strength (0...1). Updates a selected redaction element live so
    /// its mosaic/blur re-renders at the new strength regardless of its size.
    func applyRedactionStrength(_ value: CGFloat) {
        style.redactionStrength = value
        if let selected, selected is PixelateElement || selected is BlurElement {
            let before = snapshot()
            selected.style.redactionStrength = value
            commit(before, "Strength")
        }
        needsDisplay = true
    }

    func flattened() -> CGImage? {
        finishTextEditing()
        return AnnotationRenderer.flatten(base: renderBase, elements: elements, ciContext: ciContext, cropRect: cropRect)
    }
}
