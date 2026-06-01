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

    init(style: AnnotationStyle) { self.style = style }

    /// Draw into a CoreGraphics context already transformed to image-pixel space (bottom-left).
    func draw(in cg: CGContext, context rc: AnnotationRenderContext) {}

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
        if style.filled {
            cg.setFillColor(style.color.withAlphaComponent(0.25).cgColor)
            cg.fill(rect)
        }
        cg.setStrokeColor(style.color.cgColor)
        cg.stroke(rect.insetBy(dx: style.strokeWidth / 2, dy: style.strokeWidth / 2))
    }
}

final class EllipseElement: TwoPointElement {
    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        cg.setLineWidth(style.strokeWidth)
        let r = rect.insetBy(dx: style.strokeWidth / 2, dy: style.strokeWidth / 2)
        if style.filled {
            cg.setFillColor(style.color.withAlphaComponent(0.25).cgColor)
            cg.fillEllipse(in: r)
        }
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

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(style.strokeWidth * 3.5, 14)
        let headAngle = CGFloat.pi / 7

        // Shaft stops short of the tip so the head looks solid.
        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * headLength * 0.6,
            y: end.y - sin(angle) * headLength * 0.6
        )
        cg.move(to: start)
        cg.addLine(to: shaftEnd)
        cg.strokePath()

        let left = CGPoint(x: end.x - cos(angle - headAngle) * headLength,
                           y: end.y - sin(angle - headAngle) * headLength)
        let right = CGPoint(x: end.x - cos(angle + headAngle) * headLength,
                            y: end.y - sin(angle + headAngle) * headLength)
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

final class PixelateElement: TwoPointElement {
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
        filter.scale = Float(max(8, min(r.width, r.height) / 12))
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
        TextElement(origin: origin, text: text, style: style)
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
    var number: Int

    init(center: CGPoint, number: Int, style: AnnotationStyle) {
        self.center = center
        self.number = number
        super.init(style: style)
    }

    private var radius: CGFloat { max(16, style.fontSize) }

    override var boundingBox: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    override func translate(by delta: CGSize) {
        center.x += delta.width; center.y += delta.height
    }

    override func clone() -> AnnotationElement {
        StepElement(center: center, number: number, style: style)
    }

    override func transform(_ t: CGAffineTransform) { center = center.applying(t) }

    override func draw(in cg: CGContext, context rc: AnnotationRenderContext) {
        cg.setFillColor(style.color.cgColor)
        cg.fillEllipse(in: boundingBox)

        let font = NSFont.systemFont(ofSize: radius * 1.1, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)", attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        cg.textMatrix = .identity
        cg.textPosition = CGPoint(x: center.x - width / 2, y: center.y - (ascent - descent) / 2)
        CTLineDraw(line, cg)
    }
}
