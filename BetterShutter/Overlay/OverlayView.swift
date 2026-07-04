import AppKit

/// The interactive, transparent front layer of one screen's capture overlay — styled after
/// CleanShot X. It shows a dark dim with the selection cut out crisp, a thin white selection
/// border with eight grab handles, a rule-of-thirds grid, a live dimension pill, the magnifier
/// loupe, and a floating liquid-glass action bar. The selection is adjustable after drawing:
/// drag a handle to resize, drag inside to move, drag outside to start over.
///
/// The crisp frozen screenshot is shown by a sibling view behind this one; this view leaves
/// the selected region uncovered so it shows through.
///
/// All chrome is plain CALayers (solid colors, borders) rather than a `draw(_:)` override: a
/// full-screen layer-backed view with custom drawing allocates a screen-sized backing bitmap
/// (~60 MB per Retina 5K display), while solid-color layers cost effectively nothing. Only the
/// small loupe (`LoupeView`) and dimension text rasterize, both a few hundred KB.
@MainActor
final class OverlayView: NSView {

    // Inputs
    private let frozenImage: CGImage
    private let pixelSize: CGSize
    var windowHits: [WindowHighlighter.Hit] = []
    /// When true, window hover-highlight and click-to-pick are only active while Space is held —
    /// the merged screenshot flow: drag = region, hold Space = pick a window (native-screenshot style).
    var windowPickRequiresSpace = false
    var magnifierEnabled = true
    /// When true, releasing the drag captures immediately (no adjustable pending state / handles) —
    /// used by the Quick Screenshot and Screenshot & Markup flows.
    var instantCapture = false
    /// When non-empty, a confirmed selection shows the action bar with these buttons. When empty
    /// (recording / OCR flows), confirming a selection just reports `.capture`.
    var toolbarActions: [OverlayAction] = []
    /// Locks the selection to this aspect ratio (width / height). `nil` = free. Holding Shift while
    /// dragging always locks to 1:1 regardless, matching the native screenshot gesture.
    var lockedAspect: CGFloat?
    /// An initial selection (view coords) to restore as an adjustable pending selection when the
    /// overlay appears — the All-in-One "remembers your last selection" behavior. `nil` = start empty.
    var initialSelection: CGRect?

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
    private var shiftHeld = false
    private var trackingArea: NSTrackingArea?
    private var actionBar: CaptureActionBar?
    private var finished = false   // one-shot guard: a confirmed selection fires exactly once

    // Chrome layers (created once, laid out by refreshChrome()).
    private let dimLayers = (0..<4).map { _ in CALayer() }           // top, bottom, left, right
    private let windowHighlightLayer = CALayer()
    private let crosshairLayers = (0..<2).map { _ in CALayer() }     // vertical, horizontal
    private let borderLayer = CALayer()
    private let gridLayers = (0..<4).map { _ in CALayer() }          // 2 vertical, 2 horizontal
    private let handleLayers = Handle.allCases.map { _ in CALayer() }
    private let dimensionPill = CALayer()
    private let dimensionText = CATextLayer()
    private var loupe: LoupeView?

    private let minSelectionSide: CGFloat = 4
    private let handleHitRadius: CGFloat = 11
    private let handleSize: CGFloat = 9

    init(frozenImage: CGImage, pixelSize: CGSize, frame: NSRect) {
        self.frozenImage = frozenImage
        self.pixelSize = pixelSize
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        setupChromeLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Chrome layers

    private func setupChromeLayers() {
        guard let root = layer else { return }
        for l in dimLayers {
            l.backgroundColor = NSColor.black.withAlphaComponent(0.40).cgColor
            root.addSublayer(l)
        }
        windowHighlightLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        windowHighlightLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        windowHighlightLayer.borderWidth = 2
        windowHighlightLayer.isHidden = true
        root.addSublayer(windowHighlightLayer)
        for l in crosshairLayers {
            l.backgroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
            root.addSublayer(l)
        }
        borderLayer.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        borderLayer.borderWidth = 1
        borderLayer.isHidden = true
        root.addSublayer(borderLayer)
        for l in gridLayers {
            l.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
            l.isHidden = true
            root.addSublayer(l)
        }
        for l in handleLayers {
            l.backgroundColor = NSColor.white.cgColor
            l.cornerRadius = 2
            l.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
            l.borderWidth = 0.5
            l.isHidden = true
            root.addSublayer(l)
        }
        dimensionPill.backgroundColor = GlassTokens.Fixed.dimensionPill.cgColor
        dimensionPill.cornerRadius = 6
        dimensionPill.isHidden = true
        dimensionPill.addSublayer(dimensionText)
        root.addSublayer(dimensionPill)
    }

    /// Re-lays out every chrome layer from the current state. The layer-based equivalent of the
    /// old full-view `draw(_:)` — called wherever the view used to set `needsDisplay`.
    private func refreshChrome() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Only an actual selection brightens (cuts a hole). Hovering a window keeps the whole
        // screen dimmed and just outlines the clickable window — it does NOT brighten it.
        let hole = activeRect
        layoutDim(around: hole)

        if let r = hole {
            // A CALayer border draws inside its frame; outset by half the line so it straddles the
            // rect edge like the old centered NSBezierPath stroke.
            borderLayer.isHidden = false
            borderLayer.frame = r.insetBy(dx: -0.5, dy: -0.5)
            layoutGrid(in: r)
            let showHandles = hasCommittedSelection
            for (i, h) in Handle.allCases.enumerated() {
                handleLayers[i].isHidden = !showHandles
                guard showHandles else { continue }
                let c = handlePoint(h, in: r)
                handleLayers[i].frame = CGRect(
                    x: c.x - handleSize / 2, y: c.y - handleSize / 2,
                    width: handleSize, height: handleSize
                )
            }
            layoutDimensionPill(for: r)
        } else {
            borderLayer.isHidden = true
            gridLayers.forEach { $0.isHidden = true }
            handleLayers.forEach { $0.isHidden = true }
            dimensionPill.isHidden = true
        }

        if hole == nil, phase == .idle, let h = hoveredWindow?.rect {
            windowHighlightLayer.isHidden = false
            windowHighlightLayer.frame = h
        } else {
            windowHighlightLayer.isHidden = true
        }

        // Crosshair + loupe only while pointing (idle / dragging), not while adjusting.
        let pointing = !hasCommittedSelection
        crosshairLayers.forEach { $0.isHidden = !pointing }
        if pointing {
            crosshairLayers[0].frame = CGRect(x: mousePoint.x - 0.5, y: bounds.minY, width: 1, height: bounds.height)
            crosshairLayers[1].frame = CGRect(x: bounds.minX, y: mousePoint.y - 0.5, width: bounds.width, height: 1)
        }
        updateLoupe(visible: pointing && magnifierEnabled)
    }

    private func layoutDim(around hole: CGRect?) {
        let b = bounds
        guard let h = hole else {
            dimLayers[0].frame = b
            for l in dimLayers.dropFirst() { l.frame = .zero }
            return
        }
        dimLayers[0].frame = CGRect(x: b.minX, y: h.maxY, width: b.width, height: max(0, b.maxY - h.maxY))
        dimLayers[1].frame = CGRect(x: b.minX, y: b.minY, width: b.width, height: max(0, h.minY - b.minY))
        dimLayers[2].frame = CGRect(x: b.minX, y: h.minY, width: max(0, h.minX - b.minX), height: h.height)
        dimLayers[3].frame = CGRect(x: h.maxX, y: h.minY, width: max(0, b.maxX - h.maxX), height: h.height)
    }

    private func layoutGrid(in r: CGRect) {
        let show = r.width > 40 && r.height > 40
        for (i, l) in gridLayers.enumerated() {
            l.isHidden = !show
            guard show else { continue }
            if i < 2 {
                let x = r.minX + r.width * CGFloat(i + 1) / 3
                l.frame = CGRect(x: x - 0.25, y: r.minY, width: 0.5, height: r.height)
            } else {
                let y = r.minY + r.height * CGFloat(i - 1) / 3
                l.frame = CGRect(x: r.minX, y: y - 0.25, width: r.width, height: 0.5)
            }
        }
    }

    private static let dimensionAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
    private var dimensionString = ""
    private var dimensionTextSize: CGSize = .zero

    private func layoutDimensionPill(for r: CGRect) {
        let wpx = Int((r.width * sx).rounded())
        let hpx = Int((r.height * sy).rounded())
        let text = "\(wpx) × \(hpx)"
        let padding: CGFloat = 6
        // Re-measure and re-rasterize the text layer only when the label actually changed; the
        // pill frame math still runs every event so it follows a fixed-size selection being moved.
        if text != dimensionString {
            dimensionString = text
            dimensionTextSize = (text as NSString).size(withAttributes: Self.dimensionAttrs)
            dimensionText.string = NSAttributedString(string: text, attributes: Self.dimensionAttrs)
            dimensionText.frame = CGRect(x: padding, y: padding / 2,
                                         width: ceil(dimensionTextSize.width),
                                         height: ceil(dimensionTextSize.height))
        }
        let size = dimensionTextSize
        let boxW = size.width + padding * 2
        let boxH = size.height + padding
        var origin = CGPoint(x: r.minX, y: r.maxY + 7)
        if origin.y + boxH > bounds.maxY { origin.y = r.minY - boxH - 7 }
        origin.x = min(max(bounds.minX + 2, origin.x), bounds.maxX - boxW - 2)
        dimensionPill.isHidden = false
        dimensionPill.frame = CGRect(origin: origin, size: CGSize(width: boxW, height: boxH))
    }

    private func updateLoupe(visible: Bool) {
        guard visible else { loupe?.isHidden = true; return }
        if loupe == nil {
            let v = LoupeView(image: frozenImage)
            addSubview(v)
            loupe = v
        }
        loupe?.isHidden = false
        loupe?.update(anchor: mousePoint, pixelPoint: pixelPoint(for: mousePoint), overlayBounds: bounds)
    }

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

    override func layout() {
        super.layout()
        refreshChrome()
    }

    // MARK: Scale helpers

    private var sx: CGFloat { bounds.width > 0 ? pixelSize.width / bounds.width : 1 }
    private var sy: CGFloat { bounds.height > 0 ? pixelSize.height / bounds.height : 1 }

    private func pixelPoint(for p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * sx, y: (bounds.height - p.y) * sy)
    }

    /// The aspect ratio (width / height) currently enforced, or `nil` for a free selection.
    /// Shift forces a square; otherwise the configured `lockedAspect` (if any) applies.
    private var effectiveAspect: CGFloat? {
        if shiftHeld { return 1 }
        return lockedAspect
    }

    /// The rect currently shown (live drag or committed selection), in view coords.
    private var activeRect: CGRect? {
        switch phase {
        case .dragging:
            guard let anchor = dragAnchor else { return nil }
            if let aspect = effectiveAspect {
                return SelectionModel.rect(from: anchor, to: mousePoint, aspect: aspect)
                    .intersection(bounds)
            }
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

    /// Whether hovering/clicking a window picks it right now.
    private var windowPickActive: Bool {
        !windowHits.isEmpty && (!windowPickRequiresSpace || spaceHeld)
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
        if let aspect = effectiveAspect {
            return aspectResized(r, handle: handle, to: m, aspect: aspect).intersection(bounds)
        }
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

    /// Resize keeping `aspect` (width / height). Corner handles pin the opposite corner; edge handles
    /// pin the opposite edge and grow the locked perpendicular dimension symmetrically about the axis.
    private func aspectResized(_ r: CGRect, handle: Handle, to m: CGPoint, aspect: CGFloat) -> CGRect {
        switch handle {
        case .tl: return SelectionModel.rect(from: CGPoint(x: r.maxX, y: r.minY), to: m, aspect: aspect)
        case .tr: return SelectionModel.rect(from: CGPoint(x: r.minX, y: r.minY), to: m, aspect: aspect)
        case .bl: return SelectionModel.rect(from: CGPoint(x: r.maxX, y: r.maxY), to: m, aspect: aspect)
        case .br: return SelectionModel.rect(from: CGPoint(x: r.minX, y: r.maxY), to: m, aspect: aspect)
        case .t:
            let h = max(1, m.y - r.minY); let w = h * aspect
            return CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: h)
        case .b:
            let h = max(1, r.maxY - m.y); let w = h * aspect
            return CGRect(x: r.midX - w / 2, y: r.maxY - h, width: w, height: h)
        case .l:
            let w = max(1, r.maxX - m.x); let h = w / aspect
            return CGRect(x: r.maxX - w, y: r.midY - h / 2, width: w, height: h)
        case .r:
            let w = max(1, m.x - r.minX); let h = w / aspect
            return CGRect(x: r.minX, y: r.midY - h / 2, width: w, height: h)
        }
    }

    // MARK: Mouse

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dimensionText.contentsScale = window?.backingScaleFactor ?? 2
        updateCursor()
        if phase == .idle, let rect = initialSelection?.intersection(bounds),
           rect.width >= minSelectionSide, rect.height >= minSelectionSide {
            selectionRect = rect
            enterPending()   // adjustable + action bar shown, ready to confirm or tweak
        }
        initialSelection = nil
        refreshChrome()
    }

    override func mouseMoved(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        if phase == .idle {
            hoveredWindow = windowPickActive ? WindowHighlighter.window(at: mousePoint, in: windowHits) : nil
        }
        updateCursor()
        refreshChrome()
    }

    override func mouseDown(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        shiftHeld = event.modifierFlags.contains(.shift)

        if hasCommittedSelection {
            if let h = handle(at: mousePoint, in: selectionRect) {
                phase = .resizing(h)
                refreshChrome()
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

        dragAnchor = mousePoint
        phase = .dragging
        updateCursor()
        refreshChrome()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        shiftHeld = event.modifierFlags.contains(.shift)
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
        updateCursor()
        refreshChrome()
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
            let r: CGRect
            if let aspect = effectiveAspect {
                r = SelectionModel.rect(from: anchor, to: mousePoint, aspect: aspect).intersection(bounds)
            } else {
                r = SelectionModel.rect(from: anchor, to: mousePoint)
            }
            dragAnchor = nil
            if r.width < minSelectionSide || r.height < minSelectionSide {
                // Treated as a click: capture the window under the cursor, if any.
                phase = .idle
                updateCursor()
                if windowPickActive, let hit = WindowHighlighter.window(at: mousePoint, in: windowHits) {
                    onWindowSelected?(hit.id)
                } else {
                    refreshChrome()
                }
                return
            }
            selectionRect = r
            if instantCapture { confirm(.capture) } else { enterPending() }
        default:
            break
        }
        refreshChrome()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // esc
            onCancel?()
        case 36, 76: // return / keypad enter
            if hasCommittedSelection { confirm(.capture) }
        case 49: // space
            guard !event.isARepeat else { return }
            spaceHeld = true
            enteredWindowPick()
        case 123, 124, 125, 126: // arrows
            handleArrow(event)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49 else { return }
        spaceHeld = false
        leftWindowPick()
    }

    /// Space pressed: with space-gated window pick, refresh the hover highlight so the window under
    /// the cursor lights up immediately (not only on the next mouse move).
    private func enteredWindowPick() {
        guard windowPickRequiresSpace, phase == .idle else { return }
        hoveredWindow = windowPickActive ? WindowHighlighter.window(at: mousePoint, in: windowHits) : nil
        updateCursor()
        refreshChrome()
    }

    /// Space released: drop back to plain region selection.
    private func leftWindowPick() {
        guard windowPickRequiresSpace else { return }
        hoveredWindow = nil
        updateCursor()
        refreshChrome()
    }

    override func flagsChanged(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        guard shift != shiftHeld else { return super.flagsChanged(with: event) }
        shiftHeld = shift
        // Re-apply the constraint to the live selection so toggling Shift mid-resize updates it.
        if case .resizing(let h) = phase {
            selectionRect = resized(selectionRect, handle: h, to: mousePoint)
            layoutActionBar()
        }
        refreshChrome()
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
        refreshChrome()
    }

    // MARK: Phase transitions

    private func enterPending() {
        phase = .pending
        updateCursor()
        showActionBar()
        refreshChrome()
    }

    // MARK: Cursor

    /// Sets a context-appropriate pointer. With the magnifier on, the loupe stands in for the cursor,
    /// so the system cursor stays hidden instead.
    private func updateCursor() {
        if magnifierEnabled { setCursorHidden?(true); return }
        setCursorHidden?(false)
        let cursor: NSCursor
        switch phase {
        case .idle:
            cursor = windowPickActive && WindowHighlighter.window(at: mousePoint, in: windowHits) != nil
                ? .pointingHand : .crosshair
        case .dragging:
            cursor = .crosshair
        case .moving:
            cursor = .closedHand
        case .resizing(let h):
            cursor = Self.resizeCursor(for: h)
        case .pending:
            if let h = handle(at: mousePoint, in: selectionRect) { cursor = Self.resizeCursor(for: h) }
            else if selectionRect.contains(mousePoint) { cursor = .openHand }
            else { cursor = .crosshair }
        }
        cursor.set()
    }

    /// Public NSCursor lacks diagonal-resize variants, so corners fall back to the nearest axis cursor.
    private static func resizeCursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .l, .r: return .resizeLeftRight
        case .t, .b: return .resizeUpDown
        case .tl, .br, .tr, .bl: return .crosshair
        }
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
}
