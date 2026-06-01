import AppKit

/// The interactive, transparent front layer of one screen's capture overlay — styled after
/// CleanShot X. It draws a dark dim with the selection cut out crisp, a thin white selection
/// border with eight grab handles, a rule-of-thirds grid, a live dimension pill, the magnifier
/// loupe, and a floating liquid-glass action bar. The selection is adjustable after drawing:
/// drag a handle to resize, drag inside to move, drag outside to start over.
///
/// The crisp frozen screenshot is shown by a sibling image view behind this one; this view leaves
/// the selected region undrawn so it shows through.
@MainActor
final class OverlayView: NSView {

    // Inputs
    private let frozenImage: CGImage
    private let pixelSize: CGSize
    var windowHits: [WindowHighlighter.Hit] = []
    var magnifierEnabled = true
    /// When non-empty, a confirmed selection shows the action bar with these buttons. When empty
    /// (recording / OCR flows), confirming a selection just reports `.capture`.
    var toolbarActions: [OverlayAction] = []

    // Callbacks (selection reported in this view's coordinates).
    var onRegionSelected: ((CGRect, OverlayAction) -> Void)?
    var onWindowSelected: ((CGWindowID) -> Void)?
    var onCancel: (() -> Void)?
    /// Asks the owning controller to hide/show the system cursor (it owns the balance counter).
    var setCursorHidden: ((Bool) -> Void)?

    // State
    private enum Phase: Equatable { case idle, dragging, pending, moving, resizing(Handle) }
    private enum Handle: CaseIterable, Equatable { case tl, tr, bl, br, t, b, l, r }

    private var phase: Phase = .idle
    private var mousePoint: CGPoint = .zero
    private var dragAnchor: CGPoint?
    private var selectionRect: CGRect = .zero
    private var moveStart: CGPoint = .zero
    private var moveOrigin: CGRect = .zero
    private var didMove = false
    private var hoveredWindow: WindowHighlighter.Hit?
    private var spaceHeld = false
    private var trackingArea: NSTrackingArea?
    private var actionBar: CaptureActionBar?
    private var finished = false   // one-shot guard: a confirmed selection fires exactly once

    private let minSelectionSide: CGFloat = 4
    private let handleHitRadius: CGFloat = 11
    private let handleSize: CGFloat = 9

    init(frozenImage: CGImage, pixelSize: CGSize, frame: NSRect) {
        self.frozenImage = frozenImage
        self.pixelSize = pixelSize
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
        case .pending, .moving, .resizing:
            return selectionRect
        case .idle:
            return nil
        }
    }

    private var hasCommittedSelection: Bool {
        switch phase { case .pending, .moving, .resizing: return true; default: return false }
    }

    // MARK: Handle geometry

    private func handlePoint(_ h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .tl: return CGPoint(x: r.minX, y: r.maxY)
        case .tr: return CGPoint(x: r.maxX, y: r.maxY)
        case .bl: return CGPoint(x: r.minX, y: r.minY)
        case .br: return CGPoint(x: r.maxX, y: r.minY)
        case .t:  return CGPoint(x: r.midX, y: r.maxY)
        case .b:  return CGPoint(x: r.midX, y: r.minY)
        case .l:  return CGPoint(x: r.minX, y: r.midY)
        case .r:  return CGPoint(x: r.maxX, y: r.midY)
        }
    }

    private func handle(at p: CGPoint, in r: CGRect) -> Handle? {
        Handle.allCases.first { hypot(p.x - handlePoint($0, in: r).x, p.y - handlePoint($0, in: r).y) <= handleHitRadius }
    }

    private func resized(_ r: CGRect, handle: Handle, to m: CGPoint) -> CGRect {
        var (minX, maxX, minY, maxY) = (r.minX, r.maxX, r.minY, r.maxY)
        switch handle {
        case .tl: minX = m.x; maxY = m.y
        case .tr: maxX = m.x; maxY = m.y
        case .bl: minX = m.x; minY = m.y
        case .br: maxX = m.x; minY = m.y
        case .t:  maxY = m.y
        case .b:  minY = m.y
        case .l:  minX = m.x
        case .r:  maxX = m.x
        }
        let rect = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        return rect.intersection(bounds)
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

        if hasCommittedSelection {
            if let h = handle(at: mousePoint, in: selectionRect) {
                phase = .resizing(h)
                needsDisplay = true
                return
            }
            if selectionRect.contains(mousePoint) {
                phase = .moving
                moveStart = mousePoint
                moveOrigin = selectionRect
                didMove = false
                return
            }
            // Clicked outside → discard and start a fresh drag.
            hideActionBar()
        }

        setCursorHidden?(true)
        dragAnchor = mousePoint
        phase = .dragging
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch phase {
        case .moving:
            let dx = p.x - moveStart.x, dy = p.y - moveStart.y
            if abs(dx) > 2 || abs(dy) > 2 { didMove = true }
            var r = moveOrigin.offsetBy(dx: dx, dy: dy)
            r.origin.x = min(max(bounds.minX, r.minX), bounds.maxX - r.width)
            r.origin.y = min(max(bounds.minY, r.minY), bounds.maxY - r.height)
            selectionRect = r
            layoutActionBar()
        case .resizing(let h):
            selectionRect = resized(selectionRect, handle: h, to: p)
            layoutActionBar()
        case .dragging:
            if spaceHeld, let anchor = dragAnchor {
                let delta = CGPoint(x: p.x - mousePoint.x, y: p.y - mousePoint.y)
                dragAnchor = CGPoint(x: anchor.x + delta.x, y: anchor.y + delta.y)
            }
        default:
            break
        }
        mousePoint = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        switch phase {
        case .moving:
            // A click (no real movement) inside the selection confirms the capture.
            if !didMove { confirm(.capture) } else { enterPending() }
        case .resizing:
            enterPending()
        case .dragging:
            guard let anchor = dragAnchor else { return }
            let r = SelectionModel.rect(from: anchor, to: mousePoint)
            dragAnchor = nil
            if r.width < minSelectionSide || r.height < minSelectionSide {
                // Treated as a click: capture the window under the cursor, if any.
                phase = .idle
                setCursorHidden?(false)
                if let hit = WindowHighlighter.window(at: mousePoint, in: windowHits) {
                    onWindowSelected?(hit.id)
                } else {
                    needsDisplay = true
                }
                return
            }
            selectionRect = r
            enterPending()
        default:
            break
        }
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // esc
            onCancel?()
        case 36, 76: // return / keypad enter
            if hasCommittedSelection { confirm(.capture) }
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
        guard hasCommittedSelection else { return }
        let resizing = event.modifierFlags.contains(.shift)
        var model = SelectionModel()
        model.rect = selectionRect
        let step: CGFloat = 1
        switch event.keyCode {
        case 123: resizing ? model.resize(dw: -step, dh: 0, in: bounds) : model.nudge(dx: -step, dy: 0, in: bounds)
        case 124: resizing ? model.resize(dw: step, dh: 0, in: bounds) : model.nudge(dx: step, dy: 0, in: bounds)
        case 125: resizing ? model.resize(dw: 0, dh: -step, in: bounds) : model.nudge(dx: 0, dy: -step, in: bounds)
        case 126: resizing ? model.resize(dw: 0, dh: step, in: bounds) : model.nudge(dx: 0, dy: step, in: bounds)
        default: break
        }
        if let r = model.rect { selectionRect = r }
        layoutActionBar()
        needsDisplay = true
    }

    // MARK: Phase transitions

    private func enterPending() {
        phase = .pending
        setCursorHidden?(false)
        showActionBar()
        needsDisplay = true
    }

    private func confirm(_ action: OverlayAction) {
        guard !finished else { return }
        guard selectionRect.width >= minSelectionSide, selectionRect.height >= minSelectionSide else { return }
        finished = true
        onRegionSelected?(selectionRect, action)
    }

    // MARK: Action bar

    private func showActionBar() {
        guard !toolbarActions.isEmpty else { return }
        if actionBar == nil {
            let bar = CaptureActionBar(actions: toolbarActions)
            bar.onAction = { [weak self] action in self?.confirm(action) }
            bar.onCancel = { [weak self] in self?.onCancel?() }
            addSubview(bar)
            actionBar = bar
        }
        layoutActionBar()
    }

    private func hideActionBar() {
        actionBar?.removeFromSuperview()
        actionBar = nil
    }

    private func layoutActionBar() {
        guard let bar = actionBar else { return }
        let w = bar.frame.width, h = bar.frame.height
        let gap: CGFloat = 10
        var x = selectionRect.midX - w / 2
        x = min(max(bounds.minX + 6, x), bounds.maxX - w - 6)
        var y = selectionRect.minY - h - gap          // below the selection
        if y < bounds.minY + 6 { y = selectionRect.maxY + gap } // flip above
        y = min(max(bounds.minY + 6, y), bounds.maxY - h - 6)
        bar.frame = NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Only an actual selection brightens (cuts a hole). Hovering a window keeps the whole screen
        // dimmed and just outlines the clickable window — it does NOT brighten it.
        drawDim(around: activeRect)

        if let r = activeRect {
            drawSelectionChrome(r)
        } else if phase == .idle, let h = hoveredWindow?.rect {
            drawWindowHighlight(rect: h)
        }

        // Magnifier + crosshair only while pointing (idle / dragging), not while adjusting.
        if !hasCommittedSelection {
            drawCrosshair(at: mousePoint)
            if magnifierEnabled {
                MagnifierLoupe.draw(
                    at: mousePoint,
                    image: frozenImage,
                    pixelPoint: pixelPoint(for: mousePoint),
                    viewBounds: bounds
                )
            }
        }
    }

    private func fill(_ rect: NSRect) { NSBezierPath(rect: rect).fill() }

    private func drawDim(around hole: CGRect?) {
        NSColor.black.withAlphaComponent(0.40).setFill()
        guard let h = hole else { fill(bounds); return }
        let b = bounds
        fill(NSRect(x: b.minX, y: h.maxY, width: b.width, height: b.maxY - h.maxY))            // top
        fill(NSRect(x: b.minX, y: b.minY, width: b.width, height: h.minY - b.minY))            // bottom
        fill(NSRect(x: b.minX, y: h.minY, width: h.minX - b.minX, height: h.height))           // left
        fill(NSRect(x: h.maxX, y: h.minY, width: b.maxX - h.maxX, height: h.height))           // right
    }

    private func drawSelectionChrome(_ r: CGRect) {
        // Thin white border.
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1
        border.stroke()

        drawThirdsGrid(in: r)
        if hasCommittedSelection { drawHandles(in: r) }
        drawDimensions(for: r)
    }

    private func drawThirdsGrid(in r: CGRect) {
        guard r.width > 40, r.height > 40 else { return }
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3
            let y = r.minY + r.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: r.minY)); path.line(to: CGPoint(x: x, y: r.maxY))
            path.move(to: CGPoint(x: r.minX, y: y)); path.line(to: CGPoint(x: r.maxX, y: y))
        }
        path.stroke()
    }

    private func drawHandles(in r: CGRect) {
        let s = handleSize
        for h in Handle.allCases {
            let c = handlePoint(h, in: r)
            let box = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
            let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    private func drawWindowHighlight(rect: CGRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: rect).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawCrosshair(at p: CGPoint) {
        NSColor.white.withAlphaComponent(0.45).setStroke()
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
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 6
        let boxW = size.width + padding * 2
        let boxH = size.height + padding
        var origin = CGPoint(x: r.minX, y: r.maxY + 7)
        if origin.y + boxH > bounds.maxY { origin.y = r.minY - boxH - 7 }
        origin.x = min(max(bounds.minX + 2, origin.x), bounds.maxX - boxW - 2)
        let box = CGRect(origin: origin, size: CGSize(width: boxW, height: boxH))

        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(
            at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2),
            withAttributes: attrs
        )
    }
}
