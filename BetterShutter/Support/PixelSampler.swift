import CoreGraphics

/// Reads an exact pixel color from a CGImage by rasterizing it into a known 1×1 sRGB buffer.
/// Reliable for ScreenCaptureKit output, unlike `NSBitmapImageRep.colorAt`, which misreads SCK's
/// BGRA/display-colorspace images (returning black/wrong values).
nonisolated enum PixelSampler {
    /// - Parameters x,y: pixel coordinates in the image's top-left origin space.
    static func rgb(in image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        let w = image.width, h = image.height
        guard x >= 0, y >= 0, x < w, y < h else { return nil }

        var pixel: [UInt8] = [0, 0, 0, 0]
        let ok = pixel.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            // Offset the (upright-drawn) image so that top-left pixel (x, y) lands on the 1×1 origin.
            ctx.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(h - 1 - y), width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        guard ok else { return nil }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}
