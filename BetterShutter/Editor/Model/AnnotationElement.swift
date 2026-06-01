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

final class ArrowElement: TwoPointElement {
    override var isDegenerate: Bool { hypot(end.x - start.x, end.y - start.y) < 6 }
    // Tail (start) and head (end) are the resize handles.
    override func handlePoints() -> [CGPoint] { [start, end] }
    override func moveHandle(_ index: Int, to p: CGPoint) { if index == 0 { start = p } else { end = p } }

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
        cg.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil))
        cg.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        cg.fillPath()
        cg.textMatrix = .identity
        cg.textPosition = CGPoint(x: mid.x - tw / 2, y: mid.y - (ascent - descent) / 2)
        CTLineDraw(line, cg)
    }
}

final class PixelateElement: TwoPointElement {
    /// Mosaic block size for a region. Uses a high floor (16px) and grows with the region so even a
    /// thin text strip is averaged into blocks coarse enough to resist reconstruction — pixelate as
    /// redaction, not decoration.
    nonisolated static func secureScale(width: CGFloat, height: CGFloat) -> CGFloat {
        max(16, min(width, height) / 6)
    }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        let r = rect.integral
        guard r.width >= 2, r.height >= 2 else { return }
        // Convert bottom-left image rect → top-left for cropping the source bitmap.
        let cropRect = CGRect(
            x: r.minX, y: rc.imageSize.height - r.maxY,
            width: r.width, height: r.height
        ).integral
        guard let crop = rc.baseImage.cropping(to: cropRect) else { return }

        let ci = CIImage(cgImage: crop)
        let filter = CIFilter.pixellate()
        filter.inputImage = ci
        filter.scale = Float(Self.secureScale(width: r.width, height: r.height))
        filter.center = CGPoint(x: ci.extent.midX, y: ci.extent.midY)
        guard let output = filter.outputImage?.cropped(to: ci.extent),
              let outCG = rc.ciContext.createCGImage(output, from: ci.extent) else { return }
        cg.draw(outCG, in: r)
    }
}

/// Gaussian-blur redaction over a dragged region. Like `PixelateElement` but a soft blur; clamps
/// the source edges so the blur doesn't bleed transparency in from outside the crop.
final class BlurElement: TwoPointElement {
    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        let r = rect.integral
        guard r.width >= 2, r.height >= 2 else { return }
        // Bottom-left image rect → top-left crop rect for the source bitmap.
        let cropRect = CGRect(
            x: r.minX, y: rc.imageSize.height - r.maxY,
            width: r.width, height: r.height
        ).integral
        guard let crop = rc.baseImage.cropping(to: cropRect) else { return }

        let source = CIImage(cgImage: crop)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = source.clampedToExtent()
        filter.radius = Float(max(8, min(r.width, r.height) / 8))
        guard let output = filter.outputImage?.cropped(to: source.extent),
              let outCG = rc.ciContext.createCGImage(output, from: source.extent) else { return }
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

/// Spotlight: dims the whole image except the dragged region, to direct attention without arrows.
/// The bounding box is the bright (clear) area, so selection/hit-testing targets the focus rect.
final class SpotlightElement: TwoPointElement {
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

final class TextElement: AnnotationElement {
    /// Baseline origin in image coordinates (bottom-left).
    var origin: CGPoint
    var text: String

    init(origin: CGPoint, text: String, style: AnnotationStyle) {
        self.origin = origin
        self.text = text
        super.init(style: style)
    }

    private func line() -> CTLine {
        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text.isEmpty ? " " : text, attributes: attrs))
    }

    override var boundingBox: CGRect {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line(), &ascent, &descent, &leading))
        return CGRect(x: origin.x, y: origin.y - descent, width: width, height: ascent + descent)
    }

    override func translate(by delta: CGSize) {
        origin.x += delta.width; origin.y += delta.height
    }

    override var isDegenerate: Bool { text.isEmpty }

    override func clone() -> AnnotationElement {
        let copy = TextElement(origin: origin, text: text, style: style)
        copy.rotation = rotation
        return copy
    }

    override func transform(_ t: CGAffineTransform) { origin = origin.applying(t) }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        guard !text.isEmpty else { return }
        cg.textMatrix = .identity
        cg.textPosition = origin
        CTLineDraw(line(), cg)
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

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        guard radius >= 1 else { return }
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        cg.saveGState()
        cg.addEllipse(in: circle)
        cg.clip()
        // Enlarge the base image about the bubble center so the area beneath reads magnified.
        cg.translateBy(x: center.x, y: center.y)
        cg.scaleBy(x: zoom, y: zoom)
        cg.translateBy(x: -center.x, y: -center.y)
        cg.draw(rc.baseImage, in: CGRect(origin: .zero, size: rc.imageSize))
        cg.restoreGState()

        cg.setStrokeColor(style.color.cgColor)
        cg.setLineWidth(max(2, style.strokeWidth))
        cg.strokeEllipse(in: circle)
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
