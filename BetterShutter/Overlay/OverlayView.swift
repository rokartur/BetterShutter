import AppKit

/// The interactive, transparent front layer of one screen's capture overlay. It draws the dim,
/// the selection, crosshair, live pixel dimensions, the magnifier loupe, and window highlight,
/// and runs the selection state machine. The crisp frozen screenshot is shown by a sibling
/// image view behind this one; this view leaves the selected region undrawn so it shows through.
@MainActor
final class OverlayView: NSView {

    // Inputs
    private let frozenImage: CGImage
    private let bitmapRep: NSBitmapImageRep
    private let pixelSize: CGSize
    var windowHits: [WindowHighlighter.Hit] = []
    var magnifierEnabled = true

    // Callbacks (selection reported in this view's coordinates).
    var onRegionSelected: ((CGRect) -> Void)?
    var onWindowSelected: ((CGWindowID) -> Void)?
    var onCancel: (() -> Void)?

    // State
    private enum Phase { case idle, dragging, pending }
    private var phase: Phase = .idle
    private var mousePoint: CGPoint = .zero
    private var dragAnchor: CGPoint?
    private var selection = SelectionModel()
    private var hoveredWindow: WindowHighlighter.Hit?
    private var spaceHeld = false
    private var trackingArea: NSTrackingArea?

    private let minSelectionSide: CGFloat = 4

    init(frozenImage: CGImage, pixelSize: CGSize, frame: NSRect) {
        self.frozenImage = frozenImage
        self.pixelSize = pixelSize
        self.bitmapRep = NSBitmapImageRep(cgImage: frozenImage)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Scale helpers

    private var sx: CGFloat { bounds.width > 0 ? pixelSize.width / bounds.width : 1 }
    private var sy: CGFloat { bounds.height > 0 ? pixelSize.height / bounds.height : 1 }

    private func pixelPoint(for p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * sx, y: (bounds.height - p.y) * sy)
    }

    /// The rect currently shown (live drag or committed selection), in view coords.
    private var activeRect: CGRect? {
        switch phase {
        case .dragging:
            guard let anchor = dragAnchor else { return nil }
            return SelectionModel.rect(from: anchor, to: mousePoint)
        case .pending:
            return selection.rect
        case .idle:
            return nil
        }
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        if phase == .idle {
            hoveredWindow = WindowHighlighter.window(at: mousePoint, in: windowHits)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        // Click inside a pending selection confirms it.
        if phase == .pending, let r = selection.rect, r.contains(mousePoint) {
            confirmSelection()
            return
        }
        dragAnchor = mousePoint
        phase = .dragging
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if spaceHeld, let anchor = dragAnchor {
            // Reposition the whole in-progress selection.
            let delta = CGPoint(x: p.x - mousePoint.x, y: p.y - mousePoint.y)
            dragAnchor = CGPoint(x: anchor.x + delta.x, y: anchor.y + delta.y)
        }
        mousePoint = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        guard phase == .dragging, let anchor = dragAnchor else { return }
        let r = SelectionModel.rect(from: anchor, to: mousePoint)
        dragAnchor = nil

        if r.width < minSelectionSide || r.height < minSelectionSide {
            // Treated as a click: capture the window under the cursor, if any.
            phase = .idle
            if let hit = WindowHighlighter.window(at: mousePoint, in: windowHits) {
                onWindowSelected?(hit.id)
            } else {
                needsDisplay = true
            }
            return
        }
        selection.rect = r
        phase = .pending
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // esc
            onCancel?()
        case 36, 76: // return / keypad enter
            if phase == .pending { confirmSelection() }
        case 49: // space
            spaceHeld = true
        case 123, 124, 125, 126: // arrows
            handleArrow(event)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false }
    }

    private func handleArrow(_ event: NSEvent) {
        guard phase == .pending else { return }
        let resizing = event.modifierFlags.contains(.shift)
        let step: CGFloat = 1
        switch event.keyCode {
        case 123: resizing ? selection.resize(dw: -step, dh: 0, in: bounds) : selection.nudge(dx: -step, dy: 0, in: bounds)
        case 124: resizing ? selection.resize(dw: step, dh: 0, in: bounds) : selection.nudge(dx: step, dy: 0, in: bounds)
        case 125: resizing ? selection.resize(dw: 0, dh: -step, in: bounds) : selection.nudge(dx: 0, dy: -step, in: bounds)
        case 126: resizing ? selection.resize(dw: 0, dh: step, in: bounds) : selection.nudge(dx: 0, dy: step, in: bounds)
        default: break
        }
        needsDisplay = true
    }

    private func confirmSelection() {
        guard let r = selection.rect else { return }
        onRegionSelected?(r)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let highlight = (phase == .idle) ? hoveredWindow?.rect : nil
        drawDim(around: activeRect ?? highlight)

        if let r = activeRect {
            drawSelectionChrome(r)
        } else if let h = highlight {
            drawWindowHighlight(rect: h)
        }

        if phase != .pending {
            drawCrosshair(at: mousePoint)
            if magnifierEnabled {
                MagnifierLoupe.draw(
                    at: mousePoint,
                    image: frozenImage,
                    bitmap: bitmapRep,
                    pixelPoint: pixelPoint(for: mousePoint),
                    viewBounds: bounds
                )
            }
        }
    }

    private func fill(_ rect: NSRect) { NSBezierPath(rect: rect).fill() }

    private func drawDim(around hole: CGRect?) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        guard let h = hole else { fill(bounds); return }
        let b = bounds
        fill(NSRect(x: b.minX, y: h.maxY, width: b.width, height: b.maxY - h.maxY))            // top
        fill(NSRect(x: b.minX, y: b.minY, width: b.width, height: h.minY - b.minY))            // bottom
        fill(NSRect(x: b.minX, y: h.minY, width: h.minX - b.minX, height: h.height))           // left
        fill(NSRect(x: h.maxX, y: h.minY, width: b.maxX - h.maxX, height: h.height))           // right
    }

    private func drawSelectionChrome(_ r: CGRect) {
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1.5
        border.stroke()
        drawDimensions(for: r)
    }

    private func drawWindowHighlight(rect: CGRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawCrosshair(at p: CGPoint) {
        NSColor.white.withAlphaComponent(0.5).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: CGPoint(x: bounds.minX, y: p.y))
        path.line(to: CGPoint(x: bounds.maxX, y: p.y))
        path.move(to: CGPoint(x: p.x, y: bounds.minY))
        path.line(to: CGPoint(x: p.x, y: bounds.maxY))
        path.stroke()
    }

    private func drawDimensions(for r: CGRect) {
        let wpx = Int((r.width * sx).rounded())
        let hpx = Int((r.height * sy).rounded())
        let text = "\(wpx) × \(hpx)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 5
        let boxW = size.width + padding * 2
        let boxH = size.height + padding
        var origin = CGPoint(x: r.minX, y: r.maxY + 6)
        if origin.y + boxH > bounds.maxY { origin.y = r.minY - boxH - 6 }
        origin.x = min(max(bounds.minX + 2, origin.x), bounds.maxX - boxW - 2)
        let box = CGRect(origin: origin, size: CGSize(width: boxW, height: boxH))

        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(
            at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2),
            withAttributes: attrs
        )
    }
}
