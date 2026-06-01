import AppKit
import CoreImage

/// The editor canvas. Displays the capture aspect-fit and lets the user create, select, move, and
/// delete annotation elements. Works in image-pixel space (bottom-left) so element geometry maps
/// 1:1 to the exported bitmap.
@MainActor
final class EditorCanvasView: NSView, NSTextFieldDelegate {

    private let baseImage: CGImage
    private let imageSize: CGSize
    private let ciContext = CIContext()

    private(set) var elements: [AnnotationElement] = []
    private var selected: AnnotationElement?
    private var creating: AnnotationElement?
    private var stepCounter = 1

    var tool: ToolKind = .arrow { didSet { if tool != .select { selected = nil; needsDisplay = true } } }
    var style: AnnotationStyle

    private enum DragMode { case none, creating, moving, cropping }
    private var dragMode: DragMode = .none
    private var lastImagePoint: CGPoint = .zero
    private var didMove = false

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
    private let undoMgr = UndoManager()
    private var pending: EditorSnapshot?
    private var textPending: EditorSnapshot?

    private struct EditorSnapshot {
        let elements: [AnnotationElement]
        let cropRect: CGRect?
    }

    override var undoManager: UndoManager? { undoMgr }

    private func snapshot() -> EditorSnapshot {
        EditorSnapshot(elements: elements.map { $0.clone() }, cropRect: cropRect)
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
        let inverse = snapshot()
        undoMgr.registerUndo(withTarget: self) { $0.restore(inverse, name) }
        undoMgr.setActionName(name)
        elements = snap.elements
        cropRect = snap.cropRect
        selected = nil
        creating = nil
        dragMode = .none
        needsDisplay = true
    }

    init(image: CapturedImage) {
        self.baseImage = image.cgImage
        self.imageSize = image.pixelSize
        self.style = AnnotationStyle.makeDefault(imageWidth: image.pixelSize.width)
        super.init(frame: NSRect(origin: .zero, size: Self.fittedSize(for: image.pixelSize)))
        wantsLayer = true
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

    private var displayRect: CGRect {
        let inset = bounds.insetBy(dx: 16, dy: 16)
        guard imageSize.width > 0, imageSize.height > 0 else { return inset }
        let scale = min(inset.width / imageSize.width, inset.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private var scale: CGFloat { displayRect.width / max(imageSize.width, 1) }

    private func imagePoint(_ p: CGPoint) -> CGPoint {
        let x = (p.x - displayRect.minX) / scale
        let y = (p.y - displayRect.minY) / scale
        return CGPoint(x: min(max(0, x), imageSize.width), y: min(max(0, y), imageSize.height))
    }

    private func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: displayRect.minX + p.x * scale, y: displayRect.minY + p.y * scale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        bounds.fill()

        cg.draw(baseImage, in: displayRect)

        cg.saveGState()
        cg.translateBy(x: displayRect.minX, y: displayRect.minY)
        cg.scaleBy(x: scale, y: scale)
        let rc = AnnotationRenderContext(baseImage: baseImage, imageSize: imageSize, ciContext: ciContext)
        for element in elements { element.draw(in: cg, context: rc) }
        cg.restoreGState()

        if let selected, selected !== editingElement {
            drawSelectionHandles(for: selected)
        }
        if let cropRect { drawCropOverlay(cropRect) }
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
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1.5
        border.stroke()
    }

    private func drawSelectionHandles(for element: AnnotationElement) {
        let box = element.boundingBox
        let viewBox = CGRect(origin: viewPoint(box.origin),
                             size: CGSize(width: box.width * scale, height: box.height * scale))
            .insetBy(dx: -4, dy: -4)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: viewBox)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        finishTextEditing()
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        lastImagePoint = p
        didMove = false
        pending = snapshot()   // captured before any mutation; committed only if something changes

        switch tool {
        case .select:
            selected = elements.last { $0.hitTest(p) }
            dragMode = selected == nil ? .none : .moving
        case .text:
            beginText(at: p)
        case .step:
            let element = StepElement(center: p, number: stepCounter, style: style)
            stepCounter += 1
            elements.append(element)
            selected = element
            dragMode = .none
            commit(pending, "Add Step")
            pending = nil
        case .crop:
            cropAnchor = p
            cropRect = nil
            dragMode = .cropping
        default:
            let element = makeDragElement(at: p)
            elements.append(element)
            creating = element
            dragMode = .creating
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        switch dragMode {
        case .creating:
            creating?.updateDrag(to: p)
        case .moving:
            let delta = CGSize(width: p.x - lastImagePoint.x, height: p.y - lastImagePoint.y)
            selected?.translate(by: delta)
            lastImagePoint = p
            if delta.width != 0 || delta.height != 0 { didMove = true }
        case .cropping:
            if let anchor = cropAnchor { cropRect = SelectionModel.rect(from: anchor, to: p) }
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragMode == .creating, let creating {
            if creating.isDegenerate, let index = elements.firstIndex(where: { $0 === creating }) {
                elements.remove(at: index)
                selected = nil
            } else {
                selected = creating
                commit(pending, "Add \(tool.label)")
            }
        }
        if dragMode == .moving, didMove {
            commit(pending, "Move")
        }
        if dragMode == .cropping {
            if let r = cropRect, r.width < 5 || r.height < 5 { cropRect = nil }
            cropAnchor = nil
            if cropRect != pending?.cropRect { commit(pending, "Crop") }
        }
        pending = nil
        creating = nil
        dragMode = .none
        needsDisplay = true
    }

    private func makeDragElement(at p: CGPoint) -> AnnotationElement {
        switch tool {
        case .arrow: return ArrowElement(start: p, style: style)
        case .rectangle: return RectangleElement(start: p, style: style)
        case .ellipse: return EllipseElement(start: p, style: style)
        case .line: return LineElement(start: p, style: style)
        case .highlighter: return HighlightElement(start: p, style: style)
        case .pixelate: return PixelateElement(start: p, style: style)
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
        switch event.keyCode {
        case 51, 117: // delete / forward-delete
            deleteSelected()
        case 53: // esc
            if editingField != nil { finishTextEditing() } else { selected = nil; needsDisplay = true }
        default:
            super.keyDown(with: event)
        }
    }

    func deleteSelected() {
        guard let selected, let index = elements.firstIndex(where: { $0 === selected }) else { return }
        let before = snapshot()
        elements.remove(at: index)
        self.selected = nil
        commit(before, "Delete")
        needsDisplay = true
    }

    // MARK: Text editing

    private func beginText(at p: CGPoint) {
        textPending = snapshot()   // before the empty TextElement is appended
        let element = TextElement(origin: p, text: "", style: style)
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

    func flattened() -> CGImage? {
        finishTextEditing()
        return AnnotationRenderer.flatten(base: baseImage, elements: elements, ciContext: ciContext, cropRect: cropRect)
    }
}
