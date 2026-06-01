import AppKit

/// Draws a pixel-perfect magnifier loupe sampled from the frozen capture: a zoomed N×N pixel
/// grid centered on the cursor, a highlighted center cell, crosshair, and the center-pixel
/// color in hex + RGB. Pure drawing — no per-frame screen capture.
@MainActor
enum MagnifierLoupe {
    /// Odd source-pixel count so there is an exact center pixel.
    static let sourcePixels = 17
    /// On-screen magnification of each source pixel.
    static let cell: CGFloat = 8
    static var diameter: CGFloat { CGFloat(sourcePixels) * cell }

    /// - Parameters:
    ///   - anchor: cursor location in the view's coordinates.
    ///   - image: the frozen display bitmap (top-left origin, device pixels).
    ///   - bitmap: an `NSBitmapImageRep` over `image`, for color sampling.
    ///   - pixelPoint: cursor location in `image` pixel coordinates (top-left origin).
    ///   - viewBounds: the overlay view's bounds, used to keep the loupe on screen.
    static func draw(
        at anchor: CGPoint,
        image: CGImage,
        pixelPoint: CGPoint,
        viewBounds: CGRect
    ) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let d = diameter

        // Position the loupe offset from the cursor, flipping near edges to stay visible.
        let gap: CGFloat = 24
        var originX = anchor.x + gap
        var originY = anchor.y - gap - d
        if originX + d > viewBounds.maxX { originX = anchor.x - gap - d }
        if originY < viewBounds.minY { originY = anchor.y + gap }
        let frame = CGRect(x: originX, y: originY, width: d, height: d)

        ctx.saveGState()

        // Clip to a rounded square and fill the magnified crop.
        let clip = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        clip.addClip()

        let px = Int(pixelPoint.x.rounded())
        let py = Int(pixelPoint.y.rounded())
        let half = sourcePixels / 2
        let sourceRect = CGRect(
            x: px - half, y: py - half,
            width: sourcePixels, height: sourcePixels
        )

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(frame)

        if let crop = image.cropping(to: sourceRect) {
            ctx.interpolationQuality = .none
            // CGImage is top-left origin; flip vertically into the bottom-left view space.
            ctx.saveGState()
            ctx.translateBy(x: frame.minX, y: frame.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: d, height: d))
            ctx.restoreGState()
        }

        // Pixel grid.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(1)
        for i in 0...sourcePixels {
            let o = CGFloat(i) * cell
            ctx.move(to: CGPoint(x: frame.minX + o, y: frame.minY))
            ctx.addLine(to: CGPoint(x: frame.minX + o, y: frame.maxY))
            ctx.move(to: CGPoint(x: frame.minX, y: frame.minY + o))
            ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + o))
        }
        ctx.strokePath()

        // Center cell highlight.
        let centerCell = CGRect(
            x: frame.minX + CGFloat(half) * cell,
            y: frame.minY + CGFloat(half) * cell,
            width: cell, height: cell
        )
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(centerCell)

        ctx.restoreGState()

        // Border.
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let border = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        border.lineWidth = 1.5
        border.stroke()

        // Color readout below the loupe — reliable pixel read, not NSBitmapImageRep.colorAt
        // (which misreads ScreenCaptureKit's BGRA output and would show black/wrong colors).
        let sx = clampInt(px, max: image.width)
        let sy = clampInt(py, max: image.height)
        if let rgb = PixelSampler.rgb(in: image, x: sx, y: sy) {
            drawColorReadout(r: rgb.r, g: rgb.g, b: rgb.b, below: frame, viewBounds: viewBounds)
        }
    }

    private static func drawColorReadout(r: Int, g: Int, b: Int, below frame: CGRect, viewBounds: CGRect) {
        let hex = String(format: "#%02X%02X%02X", r, g, b)
        let text = "\(hex)   \(r) \(g) \(b)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 6
        let boxW = size.width + padding * 2 + 18
        let boxH = size.height + padding
        var boxOrigin = CGPoint(x: frame.midX - boxW / 2, y: frame.minY - boxH - 6)
        boxOrigin.x = min(max(viewBounds.minX + 2, boxOrigin.x), viewBounds.maxX - boxW - 2)
        if boxOrigin.y < viewBounds.minY { boxOrigin.y = frame.maxY + 6 }
        let box = CGRect(origin: boxOrigin, size: CGSize(width: boxW, height: boxH))

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()

        // Color swatch.
        let swatch = CGRect(x: box.minX + padding, y: box.midY - 6, width: 12, height: 12)
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).stroke()

        (text as NSString).draw(
            at: CGPoint(x: swatch.maxX + 6, y: box.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    private static func clampInt(_ v: Int, max: Int) -> Int { Swift.min(Swift.max(0, v), Swift.max(0, max - 1)) }
}
