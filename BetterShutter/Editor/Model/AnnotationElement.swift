import AppKit
import CoreText
import CoreImage
import CoreImage.CIFilterBuiltins

/// Shared drawing context handed to every element. All geometry is in **image-pixel coordinates,
/// bottom-left origin** (CoreGraphics-native), so the same `draw` code serves both the on-screen
/// canvas (scaled) and the 1:1 export.
@MainActor
struct AnnotationRenderContext {
    let baseImage: CGImage
    let imageSize: CGSize
    let ciContext: CIContext
    /// Enables per-element render caches for on-screen drawing, where the same CoreImage pipeline
    /// would otherwise re-run on every repaint (~60×/s during a drag). Export (`flatten`) leaves
    /// this false so the output path stays byte-identical to the uncached pipeline.
    var isInteractive: Bool = false
}

/// Base class for an annotation element.
@MainActor
class AnnotationElement {
    var style: AnnotationStyle
    /// Rotation in radians about the element's bounding-box center. Drawing and interaction are
    /// rotation-aware via the canvas; geometry (boundingBox / handlePoints) stays in local space.
    var rotation: CGFloat = 0

    init(style: AnnotationStyle) { self.style = style }

    /// Pins the rotation pivot during a resize gesture so the shape rotates about a fixed point
    /// instead of the live (moving) bbox center — otherwise a rotated resize "swims". Set at the
    /// start of a rotated resize, cleared at the end.
    var resizePivot: CGPoint?

    /// The rotation pivot (local bounding-box center, or the pinned pivot mid-resize).
    var rotationCenter: CGPoint { resizePivot ?? CGPoint(x: boundingBox.midX, y: boundingBox.midY) }

    /// Affine transform that rotates local space into displayed (rotated) space about the center.
    var rotationTransform: CGAffineTransform {
        guard rotation != 0 else { return .identity }
        let c = rotationCenter
        return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rotation).translatedBy(x: -c.x, y: -c.y)
    }

    /// Map a point from displayed space into the element's un-rotated local space (for hit-testing).
    func localPoint(_ p: CGPoint) -> CGPoint {
        rotation == 0 ? p : p.applying(rotationTransform.inverted())
    }

    /// Draw into a CoreGraphics context already transformed to image-pixel space (bottom-left).
    func draw(in cg: CGContext, context rc: AnnotationRenderContext) {}

    /// Draw with this element's rotation applied about its center. Call sites use this, not `draw`.
    func drawRotated(in cg: CGContext, context rc: AnnotationRenderContext) {
        guard rotation != 0 else { draw(in: cg, context: rc); return }
        cg.saveGState()
        cg.concatenate(rotationTransform)
        draw(in: cg, context: rc)
        cg.restoreGState()
    }

    /// Bounding box in image coordinates.
    var boundingBox: CGRect { .zero }

    /// Conservative bounds of everything `draw` may paint, in local (unrotated) image coordinates.
    /// Used only for dirty-rect culling/invalidation — it must contain the painted area and may
    /// overshoot. `.infinite` means "paints the whole canvas" (e.g. the spotlight dim).
    var paintBounds: CGRect { boundingBox.insetBy(dx: -style.strokeWidth, dy: -style.strokeWidth) }

    func translate(by delta: CGSize) {}

    /// Update the element while the user is still dragging it out.
    func updateDrag(to point: CGPoint) {}

    func hitTest(_ point: CGPoint) -> Bool {
        boundingBox.insetBy(dx: -8, dy: -8).contains(point)
    }

    /// True when the element is too small to be worth keeping after creation.
    var isDegenerate: Bool { false }

    /// Deep copy used by the editor's undo/redo to snapshot the document. Subclasses must override
    /// to copy their own geometry; the base value is only a placeholder for the abstract root.
    func clone() -> AnnotationElement { AnnotationElement(style: style) }

    /// Resize handles in image coordinates (bottom-left). Empty = element can't be resized (only
    /// moved). The editor draws a grab square at each point and hit-tests them by index.
    func handlePoints() -> [CGPoint] { [] }

    /// Move the handle at `index` (from `handlePoints()`) to `point`, mutating geometry in place.
    func moveHandle(_ index: Int, to point: CGPoint) {}

    /// Remap geometry through a whole-canvas transform (rotate/flip). Subclasses transform points.
    func transform(_ t: CGAffineTransform) {}

    /// Drop any cached interactive render (see `AnnotationRenderContext.isInteractive`). The caches
    /// self-invalidate by key (geometry/strength/base identity), but the canvas calls this when the
    /// base bitmap is replaced so no cache pins a stale full-res source between repaints.
    func invalidateRenderCache() {}
}

// MARK: - Two-point elements

@MainActor
class TwoPointElement: AnnotationElement {
    var start: CGPoint
    var end: CGPoint

    required init(start: CGPoint, style: AnnotationStyle) {
        self.start = start
        self.end = start
        super.init(style: style)
    }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    override var boundingBox: CGRect { rect }
    override func updateDrag(to point: CGPoint) { end = point }
    override func translate(by delta: CGSize) {
        start.x += delta.width; start.y += delta.height
        end.x += delta.width; end.y += delta.height
    }
    override var isDegenerate: Bool { rect.width < 3 && rect.height < 3 }

    /// `Self` resolves to the dynamic subclass, so this single override clones every two-point shape.
    override func clone() -> AnnotationElement {
        let copy = Self(start: start, style: style)
        copy.end = end
        copy.rotation = rotation
        return copy
    }

    /// Reset the element to span an axis-aligned rect (used by edge/corner resize).
    func setRect(_ r: CGRect) {
        start = CGPoint(x: r.minX, y: r.minY)
        end = CGPoint(x: r.maxX, y: r.maxY)
    }

    /// 8 handles: corners + edge midpoints, ordered clockwise from top-left (bottom-left origin,
    /// so maxY is the visual top).
    override func handlePoints() -> [CGPoint] {
        let r = rect
        return [
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
            CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.minX, y: r.midY),
        ]
    }

    override func transform(_ t: CGAffineTransform) {
        start = start.applying(t)
        end = end.applying(t)
    }

    override func moveHandle(_ index: Int, to p: CGPoint) {
        var (minX, maxX, minY, maxY) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        switch index {
        case 0: minX = p.x; maxY = p.y          // top-left
        case 1: maxY = p.y                      // top
        case 2: maxX = p.x; maxY = p.y          // top-right
        case 3: maxX = p.x                      // right
        case 4: maxX = p.x; minY = p.y          // bottom-right
        case 5: minY = p.y                      // bottom
        case 6: minX = p.x; minY = p.y          // bottom-left
        case 7: minX = p.x                      // left
        default: break
        }
        setRect(CGRect(x: min(minX, maxX), y: min(minY, maxY),
                       width: abs(maxX - minX), height: abs(maxY - minY)))
    }
}

final class RectangleElement: TwoPointElement {
    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        cg.setLineWidth(style.strokeWidth)
        cg.setLineJoin(.round)
        let radius = min(style.cornerRadius, min(rect.width, rect.height) / 2)

        func fillPath(_ r: CGRect) {
            if radius > 0 {
                cg.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
                cg.fillPath()
            } else {
                cg.fill(r)
            }
        }

        if style.fillMode == .fill {
            cg.setFillColor(style.color.cgColor)
            fillPath(rect)
            return
        }
        if style.fillMode == .strokeFill {
            cg.setFillColor(style.color.withAlphaComponent(0.25).cgColor)
            fillPath(rect)
        }
        cg.setLineDash(phase: 0, lengths: style.dashPattern)
        cg.setStrokeColor(style.color.cgColor)
        let stroked = rect.insetBy(dx: style.strokeWidth / 2, dy: style.strokeWidth / 2)
        if radius > 0 {
            let r = max(0, radius - style.strokeWidth / 2)
            cg.addPath(CGPath(roundedRect: stroked, cornerWidth: r, cornerHeight: r, transform: nil))
            cg.strokePath()
        } else {
            cg.stroke(stroked)
        }
    }
}

final class EllipseElement: TwoPointElement {
    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        cg.setLineWidth(style.strokeWidth)
        let r = rect.insetBy(dx: style.strokeWidth / 2, dy: style.strokeWidth / 2)
        if style.fillMode == .fill {
            cg.setFillColor(style.color.cgColor)
            cg.fillEllipse(in: r)
            return
        }
        if style.fillMode == .strokeFill {
            cg.setFillColor(style.color.withAlphaComponent(0.25).cgColor)
            cg.fillEllipse(in: r)
        }
        cg.setLineDash(phase: 0, lengths: style.dashPattern)
        cg.setStrokeColor(style.color.cgColor)
        cg.strokeEllipse(in: r)
    }
}

final class LineElement: TwoPointElement {
    override var isDegenerate: Bool { hypot(end.x - start.x, end.y - start.y) < 4 }
    // A line resizes by its two endpoints, not a bounding box, so direction is preserved.
    override func handlePoints() -> [CGPoint] { [start, end] }
    override func moveHandle(_ index: Int, to p: CGPoint) { if index == 0 { start = p } else { end = p } }
    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        cg.setStrokeColor(style.color.cgColor)
        cg.setLineWidth(style.strokeWidth)
        cg.setLineCap(.round)
        cg.setLineDash(phase: 0, lengths: style.dashPattern)
        cg.move(to: start)
        cg.addLine(to: end)
        cg.strokePath()
    }
}

// MARK: - Freehand

/// Freehand pen stroke: a smoothed path through the points sampled while dragging. Plugs into the
/// canvas's `.creating` drag mode via `updateDrag`, which appends points instead of moving an end.
class PenElement: AnnotationElement {
    var points: [CGPoint]

    required init(start: CGPoint, style: AnnotationStyle) {
        points = [start]
        super.init(style: style)
    }

    /// Stroke opacity (1 for the pen; the marker overrides to a translucent highlighter wash).
    var strokeAlpha: CGFloat { 1 }
    /// Stroke-width multiplier (the marker is much broader than the pen).
    var widthScale: CGFloat { 1 }

    override func updateDrag(to point: CGPoint) {
        // Drop near-duplicate samples so the smoothing stays stable on slow drags.
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
        points.append(point)
    }

    override var boundingBox: CGRect {
        guard let first = points.first else { return .zero }
        var (minX, maxX, minY, maxY) = (first.x, first.x, first.y, first.y)
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = style.strokeWidth * widthScale / 2 + 1
        return CGRect(x: minX - pad, y: minY - pad,
                      width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2)
    }

    override var isDegenerate: Bool {
        guard points.count >= 2 else { return true }
        let b = boundingBox
        return b.width < 3 && b.height < 3
    }

    override func translate(by delta: CGSize) {
        for i in points.indices { points[i].x += delta.width; points[i].y += delta.height }
    }

    override func transform(_ t: CGAffineTransform) {
        for i in points.indices { points[i] = points[i].applying(t) }
    }

    override func hitTest(_ point: CGPoint) -> Bool {
        guard points.count >= 2 else { return boundingBox.contains(point) }
        let tol = max(8, style.strokeWidth * widthScale / 2 + 6)
        for i in 1..<points.count where Self.distance(point, segA: points[i - 1], segB: points[i]) <= tol {
            return true
        }
        return false
    }

    override func clone() -> AnnotationElement {
        let copy = Self(start: points.first ?? .zero, style: style)
        copy.points = points
        copy.rotation = rotation
        return copy
    }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        guard !points.isEmpty else { return }
        cg.addPath(Self.smoothedPath(points))
        cg.setLineWidth(style.strokeWidth * widthScale)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setStrokeColor(style.color.withAlphaComponent(strokeAlpha).cgColor)
        cg.strokePath()
    }

    /// Catmull-Rom → cubic Bézier smoothing through the sampled points.
    static func smoothedPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count >= 3 else {
            for p in pts.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// Shortest distance from `p` to the segment a–b (for hit-testing the thin stroke).
    static func distance(_ p: CGPoint, segA a: CGPoint, segB b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Highlighter-style freehand marker: a broad, translucent stroke that layers like a real marker.
final class MarkerElement: PenElement {
    override var strokeAlpha: CGFloat { 0.4 }
    override var widthScale: CGFloat { 2.8 }
}

final class ArrowElement: TwoPointElement {
    override var isDegenerate: Bool { hypot(end.x - start.x, end.y - start.y) < 6 }
    // Tail (start) and head (end) are the resize handles.
    override func handlePoints() -> [CGPoint] { [start, end] }
    override func moveHandle(_ index: Int, to p: CGPoint) { if index == 0 { start = p } else { end = p } }

    /// Head wings fan out `headLength` from the tip beyond a degenerate-height bbox on axis-aligned
    /// arrows, and the curved style bows out up to 10% of the chord from the chord line.
    override var paintBounds: CGRect {
        let headLength = max(style.strokeWidth * 3.5, 14)
        var pad = headLength + style.strokeWidth
        if style.arrowStyle == .curved {
            pad = max(pad, hypot(end.x - start.x, end.y - start.y) * 0.1 + style.strokeWidth)
        }
        return boundingBox.insetBy(dx: -pad, dy: -pad)
    }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        cg.setStrokeColor(style.color.cgColor)
        cg.setFillColor(style.color.cgColor)
        cg.setLineWidth(style.strokeWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        let headLength = max(style.strokeWidth * 3.5, 14)
        let headAngle = CGFloat.pi / 7
        // `incoming` is the direction the head points along (tangent at the tip).
        let incoming: CGFloat

        switch style.arrowStyle {
        case .straight:
            incoming = atan2(end.y - start.y, end.x - start.x)
            let shaftEnd = CGPoint(x: end.x - cos(incoming) * headLength * 0.6,
                                   y: end.y - sin(incoming) * headLength * 0.6)
            cg.move(to: start); cg.addLine(to: shaftEnd); cg.strokePath()

        case .curved:
            // Quadratic bow: control point offset perpendicular to the chord at its midpoint.
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let chord = atan2(end.y - start.y, end.x - start.x)
            let bow = hypot(end.x - start.x, end.y - start.y) * 0.2
            let control = CGPoint(x: mid.x - sin(chord) * bow, y: mid.y + cos(chord) * bow)
            incoming = atan2(end.y - control.y, end.x - control.x)
            cg.move(to: start)
            cg.addQuadCurve(to: CGPoint(x: end.x - cos(incoming) * headLength * 0.6,
                                        y: end.y - sin(incoming) * headLength * 0.6),
                            control: control)
            cg.strokePath()

        case .elbow:
            // Right-angle path: travel along the longer axis first, then turn to the tip.
            let horizontalFirst = abs(end.x - start.x) >= abs(end.y - start.y)
            let corner = horizontalFirst ? CGPoint(x: end.x, y: start.y) : CGPoint(x: start.x, y: end.y)
            // If the final segment collapses (pure horizontal/vertical drag), the head must follow the
            // only real segment, not the would-be perpendicular turn.
            if hypot(end.x - corner.x, end.y - corner.y) < headLength {
                incoming = atan2(end.y - start.y, end.x - start.x)
            } else {
                incoming = horizontalFirst
                    ? (end.y >= start.y ? .pi / 2 : -.pi / 2)
                    : (end.x >= start.x ? 0 : .pi)
            }
            let shaftEnd = CGPoint(x: end.x - cos(incoming) * headLength * 0.6,
                                   y: end.y - sin(incoming) * headLength * 0.6)
            cg.move(to: start); cg.addLine(to: corner); cg.addLine(to: shaftEnd); cg.strokePath()
        }

        let left = CGPoint(x: end.x - cos(incoming - headAngle) * headLength,
                           y: end.y - sin(incoming - headAngle) * headLength)
        let right = CGPoint(x: end.x - cos(incoming + headAngle) * headLength,
                            y: end.y - sin(incoming + headAngle) * headLength)
        cg.move(to: end)
        cg.addLine(to: left)
        cg.addLine(to: right)
        cg.closePath()
        cg.fillPath()
    }
}

final class HighlightElement: TwoPointElement {
    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        cg.setFillColor(style.color.withAlphaComponent(0.35).cgColor)
        cg.fill(rect)
    }
}

/// A measuring ruler: a capped line annotated with its pixel length at the midpoint.
final class MeasureElement: TwoPointElement {
    override var isDegenerate: Bool { hypot(end.x - start.x, end.y - start.y) < 4 }
    override func handlePoints() -> [CGPoint] { [start, end] }
    override func moveHandle(_ index: Int, to p: CGPoint) { if index == 0 { start = p } else { end = p } }

    nonisolated static func pixelLength(from a: CGPoint, to b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    nonisolated static func label(from a: CGPoint, to b: CGPoint) -> String {
        "\(Int(pixelLength(from: a, to: b).rounded())) px"
    }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        cg.setStrokeColor(style.color.cgColor)
        cg.setLineWidth(style.strokeWidth)
        cg.setLineCap(.butt)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let tick = max(style.strokeWidth * 3, 8)
        let nx = -sin(angle) * tick, ny = cos(angle) * tick   // perpendicular cap direction

        cg.move(to: start); cg.addLine(to: end)
        cg.move(to: CGPoint(x: start.x - nx, y: start.y - ny)); cg.addLine(to: CGPoint(x: start.x + nx, y: start.y + ny))
        cg.move(to: CGPoint(x: end.x - nx, y: end.y - ny)); cg.addLine(to: CGPoint(x: end.x + nx, y: end.y + ny))
        cg.strokePath()

        // Pixel-length label on a dark pill at the midpoint (legible over any line color).
        let (line, tw, ascent, descent, pill) = pillGeometry()
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        cg.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil))
        cg.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        cg.fillPath()
        cg.textMatrix = .identity
        cg.textPosition = CGPoint(x: mid.x - tw / 2, y: mid.y - (ascent - descent) / 2)
        CTLineDraw(line, cg)
    }

    /// Midpoint label pill layout, shared by `draw` and `paintBounds`.
    private func pillGeometry() -> (line: CTLine, textWidth: CGFloat, ascent: CGFloat,
                                    descent: CGFloat, pill: CGRect) {
        let text = Self.label(from: start, to: end)
        let font = NSFont.systemFont(ofSize: max(11, style.fontSize * 0.55), weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let tw = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let padX: CGFloat = 6, padY: CGFloat = 3
        let pill = CGRect(x: mid.x - tw / 2 - padX, y: mid.y - (ascent + descent) / 2 - padY,
                          width: tw + padX * 2, height: ascent + descent + padY * 2)
        return (line, tw, ascent, descent, pill)
    }

    /// End-cap ticks extend perpendicular to the line; the label pill can stick out sideways on a
    /// near-vertical measure whose bbox is a thin sliver.
    override var paintBounds: CGRect {
        let tick = max(style.strokeWidth * 3, 8)
        let pad = tick + style.strokeWidth
        return boundingBox.insetBy(dx: -pad, dy: -pad)
            .union(pillGeometry().pill.insetBy(dx: -1, dy: -1))
    }
}

final class PixelateElement: TwoPointElement {
    /// Mosaic block size, driven by the redaction-strength slider and scaled to the **image** (not the
    /// region), so a small and a large pixelate respect the same chosen strength. Floored so even the
    /// weakest setting still averages enough to resist reconstruction.
    nonisolated static func blockSize(strength: CGFloat, imageSize: CGSize) -> CGFloat {
        let maxBlock = max(40, min(imageSize.width, imageSize.height) / 8)
        return max(8, strength * maxBlock)
    }

    // Interactive render cache: the CI pipeline re-runs only when the region, strength, or base
    // bitmap changed; every other repaint blits the cached region-sized result. Not copied by
    // `clone()` (undo snapshots stay cheap) and unused on export.
    private struct RenderKey: Equatable { let rect: CGRect; let strength: CGFloat }
    private var cachedKey: RenderKey?
    private var cachedBase: CGImage?
    private var cachedRender: CGImage?

    override func invalidateRenderCache() {
        cachedKey = nil; cachedBase = nil; cachedRender = nil
    }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        let r = rect.integral
        guard r.width >= 2, r.height >= 2 else { return }
        let key = RenderKey(rect: r, strength: style.redactionStrength)
        if rc.isInteractive, key == cachedKey, cachedBase === rc.baseImage, let cachedRender {
            cg.draw(cachedRender, in: r)
            return
        }
        // Convert bottom-left image rect → top-left for cropping the source bitmap.
        let cropRect = CGRect(
            x: r.minX, y: rc.imageSize.height - r.maxY,
            width: r.width, height: r.height
        ).integral
        guard let crop = rc.baseImage.cropping(to: cropRect) else { return }

        let ci = CIImage(cgImage: crop)
        let filter = CIFilter.pixellate()
        filter.inputImage = ci
        filter.scale = Float(Self.blockSize(strength: style.redactionStrength, imageSize: rc.imageSize))
        filter.center = CGPoint(x: ci.extent.midX, y: ci.extent.midY)
        guard let output = filter.outputImage?.cropped(to: ci.extent),
              let outCG = rc.ciContext.createCGImage(output, from: ci.extent) else { return }
        if rc.isInteractive {
            cachedKey = key; cachedBase = rc.baseImage; cachedRender = outCG
        }
        cg.draw(outCG, in: r)
    }
}

/// Gaussian-blur redaction over a dragged region. Like `PixelateElement` but a soft blur; clamps
/// the source edges so the blur doesn't bleed transparency in from outside the crop.
final class BlurElement: TwoPointElement {
    // Interactive render cache — same scheme as `PixelateElement`.
    private struct RenderKey: Equatable { let rect: CGRect; let strength: CGFloat }
    private var cachedKey: RenderKey?
    private var cachedBase: CGImage?
    private var cachedRender: CGImage?

    override func invalidateRenderCache() {
        cachedKey = nil; cachedBase = nil; cachedRender = nil
    }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        let r = rect.integral
        guard r.width >= 2, r.height >= 2 else { return }
        let key = RenderKey(rect: r, strength: style.redactionStrength)
        if rc.isInteractive, key == cachedKey, cachedBase === rc.baseImage, let cachedRender {
            cg.draw(cachedRender, in: r)
            return
        }
        // Bottom-left image rect → top-left crop rect for the source bitmap.
        let cropRect = CGRect(
            x: r.minX, y: rc.imageSize.height - r.maxY,
            width: r.width, height: r.height
        ).integral
        guard let crop = rc.baseImage.cropping(to: cropRect) else { return }

        let source = CIImage(cgImage: crop)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = source.clampedToExtent()
        // Radius driven by the strength slider, scaled to the image — independent of region size.
        let maxRadius = max(20, min(rc.imageSize.width, rc.imageSize.height) / 12)
        filter.radius = Float(max(2, style.redactionStrength * maxRadius))
        guard let output = filter.outputImage?.cropped(to: source.extent),
              let outCG = rc.ciContext.createCGImage(output, from: source.extent) else { return }
        if rc.isInteractive {
            cachedKey = key; cachedBase = rc.baseImage; cachedRender = outCG
        }
        cg.draw(outCG, in: r)
    }
}

/// Opaque solid block — hard redaction that cannot be reversed from the exported pixels.
final class BlackoutElement: TwoPointElement {
    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        cg.setFillColor(NSColor.black.cgColor)
        cg.fill(rect)
    }
}

/// Smart erase: fills the region with the average color of a thin ring just outside it, so the
/// content "disappears" into a near-uniform background — a lightweight content-aware erase (macshot's
/// fourth censor mode). Best on flat / gradient backgrounds; degrades to a flat patch on busy ones.
final class SmartEraseElement: TwoPointElement {
    // Interactive cache of the computed fill color — the four `CIAreaAverage` renders are the
    // cost, not the fill itself. Keyed by region + base identity.
    private var cachedRect: CGRect?
    private var cachedBase: CGImage?
    private var cachedColor: CGColor?

    override func invalidateRenderCache() {
        cachedRect = nil; cachedBase = nil; cachedColor = nil
    }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        let r = rect.integral
        guard r.width >= 2, r.height >= 2 else { return }
        let color: CGColor
        if rc.isInteractive, r == cachedRect, cachedBase === rc.baseImage, let cachedColor {
            color = cachedColor
        } else {
            color = Self.borderAverageColor(of: rc.baseImage, region: r,
                                            imageSize: rc.imageSize, ciContext: rc.ciContext)
            if rc.isInteractive {
                cachedRect = r; cachedBase = rc.baseImage; cachedColor = color
            }
        }
        cg.setFillColor(color)
        cg.fill(r)
    }

    /// Average color of the ring of pixels just outside `region` (image bottom-left coords).
    static func borderAverageColor(of image: CGImage, region: CGRect, imageSize: CGSize,
                                   ciContext: CIContext) -> CGColor {
        let ci = CIImage(cgImage: image)
        let m = max(4, min(region.width, region.height) * 0.15)
        let full = CGRect(origin: .zero, size: imageSize)
        let strips = [
            CGRect(x: region.minX, y: region.maxY, width: region.width, height: m),      // top
            CGRect(x: region.minX, y: region.minY - m, width: region.width, height: m),  // bottom
            CGRect(x: region.minX - m, y: region.minY, width: m, height: region.height), // left
            CGRect(x: region.maxX, y: region.minY, width: m, height: region.height),     // right
        ].map { $0.intersection(full) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }

        var (rT, gT, bT, n) = (0.0, 0.0, 0.0, 0.0)
        for strip in strips {
            if let c = averageColor(ci, extent: strip, ciContext: ciContext) {
                rT += c.0; gT += c.1; bT += c.2; n += 1
            }
        }
        guard n > 0 else { return CGColor(gray: 0.5, alpha: 1) }
        return CGColor(srgbRed: rT / n, green: gT / n, blue: bT / n, alpha: 1)
    }

    private static func averageColor(_ ci: CIImage, extent: CGRect,
                                     ciContext: CIContext) -> (Double, Double, Double)? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = ci
        filter.extent = extent
        guard let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &px, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }
}

/// Spotlight: dims the whole image except the dragged region, to direct attention without arrows.
/// The bounding box is the bright (clear) area, so selection/hit-testing targets the focus rect.
final class SpotlightElement: TwoPointElement {
    /// The dim covers the entire image, so any change repaints everything — culling it by the
    /// focus rect would leave stale dim behind.
    override var paintBounds: CGRect { .infinite }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        let full = CGRect(origin: .zero, size: rc.imageSize)
        cg.saveGState()
        cg.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        let path = CGMutablePath()
        path.addRect(full)
        path.addRect(rect)
        cg.addPath(path)
        cg.fillPath(using: .evenOdd) // outer fill minus the focus-rect hole
        cg.restoreGState()
    }
}

// MARK: - Text

/// Per-element rich-text styling for a TextElement (whole-string, not per-character).
struct TextFormatting: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var outlined = false
    var background: NSColor?
}

final class TextElement: AnnotationElement {
    /// Baseline origin in image coordinates (bottom-left).
    var origin: CGPoint
    var text: String
    var format = TextFormatting()

    init(origin: CGPoint, text: String, style: AnnotationStyle, format: TextFormatting = TextFormatting()) {
        self.origin = origin
        self.text = text
        self.format = format
        super.init(style: style)
    }

    private func font() -> NSFont {
        var font = NSFont.systemFont(ofSize: style.fontSize, weight: format.bold ? .bold : .semibold)
        if format.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    private func attributes() -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font(), .foregroundColor: style.color]
        if format.outlined {
            // Negative stroke width = stroke + fill, drawing a contrasting halo for readability.
            attrs[.strokeWidth] = -3.0
            let rgb = style.color.usingColorSpace(.sRGB)
            let lum = rgb.map { 0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent } ?? 0
            attrs[.strokeColor] = lum > 0.6 ? NSColor.black : NSColor.white
        }
        return attrs
    }

    private func line() -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes()))
    }

    private func metrics() -> (width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line(), &ascent, &descent, &leading))
        return (width, ascent, descent)
    }

    override var boundingBox: CGRect {
        let m = metrics()
        return CGRect(x: origin.x, y: origin.y - m.descent, width: m.width, height: m.ascent + m.descent)
    }

    /// Background pad (0.2/0.12 of font size), the hand-drawn underline below the descent, and the
    /// outlined halo all paint slightly outside the typographic bbox.
    override var paintBounds: CGRect {
        boundingBox.insetBy(dx: -max(style.fontSize * 0.25, 4), dy: -max(style.fontSize * 0.25, 4))
    }

    override func translate(by delta: CGSize) {
        origin.x += delta.width; origin.y += delta.height
    }

    override var isDegenerate: Bool { text.isEmpty }

    override func clone() -> AnnotationElement {
        let copy = TextElement(origin: origin, text: text, style: style, format: format)
        copy.rotation = rotation
        return copy
    }

    override func transform(_ t: CGAffineTransform) { origin = origin.applying(t) }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        guard !text.isEmpty else { return }
        let m = metrics()
        if let bg = format.background {
            let padX = style.fontSize * 0.2, padY = style.fontSize * 0.12
            cg.setFillColor(bg.cgColor)
            cg.fill(CGRect(x: origin.x - padX, y: origin.y - m.descent - padY,
                           width: m.width + padX * 2, height: m.ascent + m.descent + padY * 2))
        }
        cg.textMatrix = .identity
        cg.textPosition = origin
        CTLineDraw(line(), cg)

        // CoreText's CTLine doesn't render underline/strikethrough, so draw them by hand.
        if format.underline || format.strikethrough {
            cg.setStrokeColor(style.color.cgColor)
            cg.setLineWidth(max(1, style.fontSize * 0.06))
            if format.underline {
                let y = origin.y - m.descent * 0.4
                cg.move(to: CGPoint(x: origin.x, y: y)); cg.addLine(to: CGPoint(x: origin.x + m.width, y: y))
            }
            if format.strikethrough {
                let y = origin.y + (m.ascent - m.descent) * 0.32
                cg.move(to: CGPoint(x: origin.x, y: y)); cg.addLine(to: CGPoint(x: origin.x + m.width, y: y))
            }
            cg.strokePath()
        }
    }
}

// MARK: - Watermark

/// A text watermark — either a single placed mark or a translucent pattern tiled diagonally across
/// the whole image (Snapzy-style). Opacity and the fixed tile angle keep it readable but unobtrusive.
final class WatermarkElement: AnnotationElement {
    var text: String
    var tiled: Bool
    /// Single-mode draw point, or the tiled pattern's phase offset (so it can be nudged).
    var anchor: CGPoint
    var imageSize: CGSize
    var opacity: CGFloat
    private let angle: CGFloat = .pi / 6   // 30° diagonal for the tiled pattern

    init(text: String, tiled: Bool, anchor: CGPoint, imageSize: CGSize,
         style: AnnotationStyle, opacity: CGFloat = 0.22) {
        self.text = text
        self.tiled = tiled
        self.anchor = anchor
        self.imageSize = imageSize
        self.opacity = opacity
        super.init(style: style)
    }

    private func line() -> CTLine {
        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: style.color.withAlphaComponent(opacity),
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text.isEmpty ? " " : text, attributes: attrs))
    }

    private var textSize: CGSize {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line(), &ascent, &descent, &leading))
        return CGSize(width: w, height: ascent + descent)
    }

    override var boundingBox: CGRect {
        if tiled { return CGRect(origin: .zero, size: imageSize) }
        let s = textSize
        return CGRect(x: anchor.x, y: anchor.y, width: s.width, height: s.height)
    }

    override func translate(by delta: CGSize) { anchor.x += delta.width; anchor.y += delta.height }
    override var isDegenerate: Bool { text.isEmpty }
    override func transform(_ t: CGAffineTransform) { anchor = anchor.applying(t) }

    override func clone() -> AnnotationElement {
        let copy = WatermarkElement(text: text, tiled: tiled, anchor: anchor,
                                    imageSize: imageSize, style: style, opacity: opacity)
        copy.rotation = rotation
        return copy
    }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        guard !text.isEmpty else { return }
        cg.textMatrix = .identity
        guard tiled else { drawOne(in: cg, at: anchor); return }
        let s = textSize
        let stepX = s.width + max(60, s.width * 0.6)
        let stepY = max(80, s.height * 3)
        // Extend the grid beyond the image so the rotated pattern still covers the corners.
        var y = -stepY + anchor.y.truncatingRemainder(dividingBy: stepY)
        while y < imageSize.height + stepY {
            var x = -stepX + anchor.x.truncatingRemainder(dividingBy: stepX)
            while x < imageSize.width + stepX {
                drawOne(in: cg, at: CGPoint(x: x, y: y))
                x += stepX
            }
            y += stepY
        }
    }

    private func drawOne(in cg: CGContext, at p: CGPoint) {
        cg.saveGState()
        cg.translateBy(x: p.x, y: p.y)
        if tiled { cg.rotate(by: angle) }
        cg.textPosition = .zero
        CTLineDraw(line(), cg)
        cg.restoreGState()
    }
}

// MARK: - Numbered step badge

final class StepElement: AnnotationElement {
    var center: CGPoint
    /// 1-based position in the step sequence (maintained by the editor on add/delete).
    var number: Int
    var format: StepFormat
    /// The label value the first badge shows; later badges count up from here.
    var start: Int

    init(center: CGPoint, number: Int, style: AnnotationStyle, format: StepFormat = .decimal, start: Int = 1) {
        self.center = center
        self.number = number
        self.format = format
        self.start = start
        super.init(style: style)
    }

    private var radius: CGFloat { max(16, style.fontSize) }

    /// The rendered badge text for this step's sequence position.
    var label: String { format.string(for: start + number - 1) }

    override var boundingBox: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    override func translate(by delta: CGSize) {
        center.x += delta.width; center.y += delta.height
    }

    override func clone() -> AnnotationElement {
        let copy = StepElement(center: center, number: number, style: style, format: format, start: start)
        copy.rotation = rotation
        return copy
    }

    override func transform(_ t: CGAffineTransform) { center = center.applying(t) }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        cg.setFillColor(style.color.cgColor)
        cg.fillEllipse(in: boundingBox)

        // Fit multi-character labels (AA, VIII) inside the badge by shrinking the font to taste.
        var fontSize = radius * 1.1
        let maxWidth = radius * 1.7
        func measure(_ size: CGFloat) -> (CTLine, CGFloat, CGFloat, CGFloat) {
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            return (line, width, ascent, descent)
        }
        var (line, width, ascent, descent) = measure(fontSize)
        if width > maxWidth, width > 0 {
            fontSize *= maxWidth / width
            (line, width, ascent, descent) = measure(fontSize)
        }
        cg.textMatrix = .identity
        cg.textPosition = CGPoint(x: center.x - width / 2, y: center.y - (ascent - descent) / 2)
        CTLineDraw(line, cg)
    }
}

// MARK: - Loupe (magnifier bubble)

/// A circular magnifier placed over the capture: shows the base image beneath it enlarged. Drag to
/// set the radius; one handle resizes; the whole bubble moves.
final class LoupeElement: AnnotationElement {
    var center: CGPoint
    var radius: CGFloat = 0
    var zoom: CGFloat

    init(center: CGPoint, style: AnnotationStyle, zoom: CGFloat = 2) {
        self.center = center
        self.zoom = zoom
        super.init(style: style)
    }

    override var boundingBox: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
    /// The border stroke straddles the circle edge.
    override var paintBounds: CGRect {
        boundingBox.insetBy(dx: -max(2, style.strokeWidth), dy: -max(2, style.strokeWidth))
    }
    override var isDegenerate: Bool { radius < 8 }
    override func updateDrag(to p: CGPoint) { radius = hypot(p.x - center.x, p.y - center.y) }
    override func translate(by delta: CGSize) { center.x += delta.width; center.y += delta.height }
    override func transform(_ t: CGAffineTransform) { center = center.applying(t) }
    override func clone() -> AnnotationElement {
        let l = LoupeElement(center: center, style: style, zoom: zoom)
        l.radius = radius; l.rotation = rotation; return l
    }
    override func handlePoints() -> [CGPoint] { [CGPoint(x: center.x + radius, y: center.y)] }
    override func moveHandle(_ index: Int, to p: CGPoint) { radius = max(8, hypot(p.x - center.x, p.y - center.y)) }

    // Interactive cache of the magnified circular patch — the full-image scaled draw is the cost.
    // The border stroke stays live-drawn so color/width tweaks don't invalidate the patch.
    private struct RenderKey: Equatable { let center: CGPoint; let radius: CGFloat; let zoom: CGFloat }
    private var cachedKey: RenderKey?
    private var cachedBase: CGImage?
    private var cachedPatch: CGImage?

    override func invalidateRenderCache() {
        cachedKey = nil; cachedBase = nil; cachedPatch = nil
    }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        guard radius >= 1 else { return }
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        if rc.isInteractive {
            let key = RenderKey(center: center, radius: radius, zoom: zoom)
            if key != cachedKey || cachedBase !== rc.baseImage || cachedPatch == nil {
                cachedPatch = renderPatch(circle: circle, context: rc)
                cachedKey = key
                cachedBase = rc.baseImage
            }
            if let patch = cachedPatch {
                // 1:1 blit at the patch's integral size; outside the clipped ellipse it's transparent.
                cg.draw(patch, in: CGRect(x: circle.minX, y: circle.minY,
                                          width: CGFloat(patch.width), height: CGFloat(patch.height)))
            } else {
                drawMagnified(in: cg, circle: circle, context: rc)
            }
        } else {
            drawMagnified(in: cg, circle: circle, context: rc)
        }

        cg.setStrokeColor(style.color.cgColor)
        cg.setLineWidth(max(2, style.strokeWidth))
        cg.strokeEllipse(in: circle)
    }

    /// The uncached magnification: clip to the bubble and draw the whole base image enlarged
    /// about the bubble center so the area beneath reads magnified.
    private func drawMagnified(in cg: CGContext, circle: CGRect, context rc: AnnotationRenderContext) {
        cg.saveGState()
        cg.addEllipse(in: circle)
        cg.clip()
        cg.translateBy(x: center.x, y: center.y)
        cg.scaleBy(x: zoom, y: zoom)
        cg.translateBy(x: -center.x, y: -center.y)
        cg.draw(rc.baseImage, in: CGRect(origin: .zero, size: rc.imageSize))
        cg.restoreGState()
    }

    /// Replay the magnified draw into a patch-sized offscreen bitmap for the interactive cache.
    private func renderPatch(circle: CGRect, context rc: AnnotationRenderContext) -> CGImage? {
        let w = max(1, Int(ceil(circle.width))), h = max(1, Int(ceil(circle.height)))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: -circle.minX, y: -circle.minY)
        drawMagnified(in: ctx, circle: circle, context: rc)
        return ctx.makeImage()
    }
}

// MARK: - Composed image

/// An additional image dropped onto the canvas (compose multiple captures into one). Movable and
/// resizable via the 8 bbox handles.
final class ImageElement: AnnotationElement {
    let image: CGImage
    var frame: CGRect

    init(image: CGImage, frame: CGRect, style: AnnotationStyle) {
        self.image = image
        self.frame = frame
        super.init(style: style)
    }

    override var boundingBox: CGRect { frame }
    override func translate(by delta: CGSize) { frame.origin.x += delta.width; frame.origin.y += delta.height }
    override var isDegenerate: Bool { frame.width < 8 || frame.height < 8 }
    override func clone() -> AnnotationElement {
        let copy = ImageElement(image: image, frame: frame, style: style)
        copy.rotation = rotation
        return copy
    }
    override func transform(_ t: CGAffineTransform) { frame = frame.applying(t) }

    override func handlePoints() -> [CGPoint] {
        let r = frame
        return [
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
            CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.minX, y: r.midY),
        ]
    }

    override func moveHandle(_ index: Int, to p: CGPoint) {
        var (minX, maxX, minY, maxY) = (frame.minX, frame.maxX, frame.minY, frame.maxY)
        switch index {
        case 0: minX = p.x; maxY = p.y
        case 1: maxY = p.y
        case 2: maxX = p.x; maxY = p.y
        case 3: maxX = p.x
        case 4: maxX = p.x; minY = p.y
        case 5: minY = p.y
        case 6: minX = p.x; minY = p.y
        case 7: minX = p.x
        default: break
        }
        frame = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        cg.draw(image, in: frame)
    }
}

// MARK: - Emoji / stamp

final class StampElement: AnnotationElement {
    var center: CGPoint
    var emoji: String
    let size: CGFloat

    init(center: CGPoint, emoji: String, style: AnnotationStyle) {
        self.center = center
        self.emoji = emoji
        self.size = max(40, style.fontSize * 2)
        super.init(style: style)
    }

    override var boundingBox: CGRect {
        CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    /// Emoji glyph metrics (ascent + descent) can exceed the nominal badge square.
    override var paintBounds: CGRect {
        boundingBox.insetBy(dx: -size * 0.25, dy: -size * 0.25)
    }

    override func translate(by delta: CGSize) {
        center.x += delta.width; center.y += delta.height
    }

    override func clone() -> AnnotationElement {
        let copy = StampElement(center: center, emoji: emoji, style: style)
        copy.rotation = rotation
        return copy
    }

    override func transform(_ t: CGAffineTransform) { center = center.applying(t) }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        let font = NSFont.systemFont(ofSize: size)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: [.font: font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        cg.textMatrix = .identity
        cg.textPosition = CGPoint(x: center.x - width / 2, y: center.y - (ascent - descent) / 2)
        CTLineDraw(line, cg)
    }
}
