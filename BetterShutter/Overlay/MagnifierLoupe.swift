import AppKit

/// Draws a clean, circular magnifier loupe sampled from the frozen capture: a zoomed pixel grid
/// centered on the cursor under a soft drop shadow, a crisp center-pixel marker, and the
/// center-pixel color in hex + RGB below. Pure drawing — no per-frame screen capture.
@MainActor
enum MagnifierLoupe {
    /// Odd source-pixel count so there is an exact center pixel.
    static let sourcePixels = 15
    /// On-screen magnification of each source pixel.
    static let cell: CGFloat = 9
    static var diameter: CGFloat { CGFloat(sourcePixels) * cell }

    /// - Parameters:
    ///   - anchor: cursor location in the view's coordinates.
    ///   - image: the frozen display bitmap (top-left origin, device pixels).
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
        let gap: CGFloat = 22
        var originX = anchor.x + gap
        var originY = anchor.y - gap - d
        if originX + d > viewBounds.maxX { originX = anchor.x - gap - d }
        if originY < viewBounds.minY { originY = anchor.y + gap }
        originX = min(max(viewBounds.minX + 4, originX), viewBounds.maxX - d - 4)
        originY = min(max(viewBounds.minY + 4, originY), viewBounds.maxY - d - 4)
        let frame = CGRect(x: originX, y: originY, width: d, height: d)
        let circle = CGPath(ellipseIn: frame, transform: nil)

        // Soft drop shadow so the loupe lifts off the screenshot.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(circle)
        ctx.fillPath()
        ctx.restoreGState()

        // Clip to the circle and fill the magnified crop.
        ctx.saveGState()
        ctx.addPath(circle)
        ctx.clip()

        let px = Int(pixelPoint.x.rounded())
        let py = Int(pixelPoint.y.rounded())
        let half = sourcePixels / 2
        let sourceRect = CGRect(x: px - half, y: py - half, width: sourcePixels, height: sourcePixels)

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(frame)

        // Clamp the sample window to the image. `cropping(to:)` returns only the intersection, so near
        // any edge the crop is smaller than the window — drawing it into the full loupe would stretch
        // it (wrong zoom) and slide the sampled pixel off the marker. Instead draw the partial crop at
        // its matching cell offset; the black fill backs the out-of-image margin. Because the window
        // stays centered on (px,py), the center cell and grid keep aligning with no further changes.
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = sourceRect.intersection(imageRect)
        if !clamped.isNull, !clamped.isEmpty, let crop = image.cropping(to: clamped) {
            ctx.interpolationQuality = .none
            // A plain CGContext.draw renders the (top-left-origin) crop upright in bottom-left
            // view space — no flip transform. Only the placement converts between origins: the
            // crop's offset from the sample window's top edge becomes an offset down from the
            // loupe frame's maxY.
            let dx = (clamped.minX - sourceRect.minX) * cell
            let dyFromTop = (clamped.minY - sourceRect.minY) * cell
            ctx.draw(crop, in: CGRect(x: frame.minX + dx,
                                      y: frame.maxY - dyFromTop - clamped.height * cell,
                                      width: clamped.width * cell, height: clamped.height * cell))
        }

        // Faint pixel grid — subtle, so it reads as precision rather than a checkerboard.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor)
        ctx.setLineWidth(1)
        for i in 0...sourcePixels {
            let o = CGFloat(i) * cell
            ctx.move(to: CGPoint(x: frame.minX + o, y: frame.minY))
            ctx.addLine(to: CGPoint(x: frame.minX + o, y: frame.maxY))
            ctx.move(to: CGPoint(x: frame.minX, y: frame.minY + o))
            ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + o))
        }
        ctx.strokePath()

        // Center-pixel marker: a white box with a dark outline so it shows on any color.
        let centerCell = CGRect(
            x: frame.minX + CGFloat(half) * cell,
            y: frame.minY + CGFloat(half) * cell,
            width: cell, height: cell
        )
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(centerCell)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(centerCell)

        ctx.restoreGState()

        // Ring border: a dark halo under a bright ring, for contrast on light and dark screens.
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(3)
        ctx.addPath(circle)
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(circle)
        ctx.strokePath()
        ctx.restoreGState()

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
        let padding: CGFloat = 7
        let boxW = size.width + padding * 2 + 18
        let boxH = size.height + padding
        var boxOrigin = CGPoint(x: frame.midX - boxW / 2, y: frame.minY - boxH - 7)
        boxOrigin.x = min(max(viewBounds.minX + 2, boxOrigin.x), viewBounds.maxX - boxW - 2)
        if boxOrigin.y < viewBounds.minY { boxOrigin.y = frame.maxY + 7 }
        let box = CGRect(origin: boxOrigin, size: CGSize(width: boxW, height: boxH))

        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()

        // Color swatch.
        let swatch = CGRect(x: box.minX + padding, y: box.midY - 6, width: 12, height: 12)
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).stroke()

        (text as NSString).draw(
            at: CGPoint(x: swatch.maxX + 6, y: box.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    private static func clampInt(_ v: Int, max: Int) -> Int { Swift.min(Swift.max(0, v), Swift.max(0, max - 1)) }
}
