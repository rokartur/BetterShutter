import CoreGraphics

/// Pure CGImage downscaling, used by the "downscale Retina to 1×" output option.
nonisolated enum ImageScaler {
    /// Return `image` shrunk by `factor` (e.g. 2 halves each dimension). `factor <= 1` returns the
    /// original. `nil` only on context-creation failure.
    static func downscaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        guard factor > 1 else { return image }
        let width = Int((CGFloat(image.width) / factor).rounded())
        let height = Int((CGFloat(image.height) / factor).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
