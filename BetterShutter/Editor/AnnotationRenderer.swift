import AppKit
import CoreImage

/// Flattens the base capture plus annotation elements into a single bitmap, at full image
/// resolution. Uses a native (bottom-left) CoreGraphics context so element drawing matches the
/// on-screen canvas exactly.
@MainActor
enum AnnotationRenderer {
    static func flatten(
        base: CGImage,
        elements: [AnnotationElement],
        ciContext: CIContext,
        cropRect: CGRect? = nil
    ) -> CGImage? {
        let width = base.width
        let height = base.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let rc = AnnotationRenderContext(
            baseImage: base,
            imageSize: CGSize(width: width, height: height),
            ciContext: ciContext
        )
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        for element in elements { element.drawRotated(in: ctx, context: rc) }
        guard let rendered = ctx.makeImage() else { return nil }

        guard let cropRect else { return rendered }
        // cropRect is in bottom-left image coords; CGImage.cropping is top-left.
        let topLeft = CGRect(
            x: cropRect.minX, y: CGFloat(height) - cropRect.maxY,
            width: cropRect.width, height: cropRect.height
        ).integral
        let clamped = CoordinateConverter.clamp(topLeft, to: CGSize(width: width, height: height))
        guard clamped.width >= 1, clamped.height >= 1 else { return rendered }
        return rendered.cropping(to: clamped) ?? rendered
    }
}
