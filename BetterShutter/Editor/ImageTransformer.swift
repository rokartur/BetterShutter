import CoreGraphics
import CoreImage

/// Whole-canvas transforms for the editor. The SAME affine is applied to the base bitmap (as a
/// context CTM) and to every annotation's points, so geometry stays consistent. All math is in
/// image-pixel, bottom-left space.
nonisolated enum ImageTransform: String, CaseIterable {
    case rotateLeft, rotateRight, flipHorizontal, flipVertical

    var actionName: String {
        switch self {
        case .rotateLeft: return "Rotate Left"
        case .rotateRight: return "Rotate Right"
        case .flipHorizontal: return "Flip Horizontal"
        case .flipVertical: return "Flip Vertical"
        }
    }
}

nonisolated enum ImageTransformer {
    /// The affine that maps old image-space points to new, plus the resulting image size.
    static func affine(_ kind: ImageTransform, width w: CGFloat, height h: CGFloat) -> (CGAffineTransform, CGSize) {
        switch kind {
        case .flipHorizontal:
            return (CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0), CGSize(width: w, height: h))
        case .flipVertical:
            return (CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h), CGSize(width: w, height: h))
        case .rotateRight: // 90° clockwise; (x,y) -> (y, w - x)
            return (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w), CGSize(width: h, height: w))
        case .rotateLeft: // 90° counter-clockwise; (x,y) -> (h - y, x)
            return (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0), CGSize(width: h, height: w))
        }
    }

    static func apply(_ kind: ImageTransform, to image: CGImage) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let (t, newSize) = affine(kind, width: w, height: h)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(newSize.width), height: Int(newSize.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func inverted(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        guard let out = filter.outputImage else { return nil }
        return CIContext().createCGImage(out, from: ci.extent)
    }
}
