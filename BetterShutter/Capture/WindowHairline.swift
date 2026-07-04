import CoreGraphics
import SwiftUI

/// Re-draws the thin light outline WindowServer composites along window edges on screen.
///
/// ScreenCaptureKit's single-window snapshot (`SCContentFilter(desktopIndependentWindow:)`)
/// returns only the window's own layer — content, rounded corners, optional shadow — without
/// the hairline the WindowServer adds at display time, unlike the native screenshot UI. The
/// window body is the only (near-)fully-opaque region of the bitmap, so its rect is found
/// from the alpha channel and the outline stroked back on. Display captures don't need this:
/// they go through `SCScreenshotManager.captureImage(in:)`, which returns the true composite.
nonisolated enum WindowHairline {

    /// Alpha at or above this counts as window body; the drop shadow peaks well below it.
    private static let bodyAlphaThreshold: UInt8 = 200

    /// Standard macOS window corner radius in points, `.continuous` (superellipse) curve.
    /// Measured by fitting CALayer corner profiles against a real Tahoe window capture.
    private static let cornerRadiusPoints: CGFloat = 16.5

    private static var strokeColor: CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.25) }

    /// The system outline follows the continuous (superellipse) corner curve, not a circular
    /// arc — a circular stroke visibly drifts off the window edge near the corners.
    private static func roundedPath(rect: CGRect, radius: CGFloat) -> CGPath {
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous).cgPath
    }

    private static func stroke(_ rect: CGRect, radius: CGFloat, lineWidth: CGFloat, in context: CGContext) {
        let path = roundedPath(
            rect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            radius: max(0, radius - lineWidth / 2)
        )
        context.setStrokeColor(strokeColor)
        context.setLineWidth(lineWidth)
        context.addPath(path)
        context.strokePath()
    }

    /// `image` with a 1 pt hairline stroked along the recovered window edge, or `nil` when
    /// the window body can't be found (fully translucent window, context failure) — callers
    /// should keep the original image in that case.
    static func stroked(on image: CGImage, scale: CGFloat) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let stride = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: stride * height)

        // Bounding box of the opaque body, read from the RGBA buffer's alpha byte (offset 3).
        // Row 0 of the buffer is the visual top.
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = pixels + y * stride
            var first = -1, last = -1
            for x in 0..<width where row[x * 4 + 3] >= bodyAlphaThreshold {
                if first < 0 { first = x }
                last = x
            }
            guard first >= 0 else { continue }
            if y < minY { minY = y }
            maxY = y
            if first < minX { minX = first }
            if last > maxX { maxX = last }
        }
        guard maxX > minX + 4, maxY > minY + 4 else { return nil }

        // Square-cornered (borderless) windows have an opaque top row edge-to-edge; standard
        // windows are inset by the corner curve there.
        let topRow = pixels + minY * stride
        let topLeftInset = (minX...maxX).first { topRow[$0 * 4 + 3] >= bodyAlphaThreshold }.map { $0 - minX } ?? 0
        let radius = topLeftInset <= Int(scale) ? 0 : cornerRadiusPoints * scale

        // Buffer bbox (top-left origin, inclusive) → CG rect (bottom-left origin).
        let body = CGRect(
            x: CGFloat(minX),
            y: CGFloat(height - maxY - 1),
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1)
        )
        stroke(body, radius: radius, lineWidth: max(1, scale.rounded()), in: context)
        return context.makeImage()
    }
}
