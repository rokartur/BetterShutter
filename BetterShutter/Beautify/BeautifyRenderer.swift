import AppKit

/// Composites a screenshot onto a padded, rounded, shadowed background. Native bottom-left
/// CoreGraphics so the image draws upright and the same code serves preview + full-res export.
@MainActor
enum BeautifyRenderer {
    static func render(base: CGImage, style: BeautifyStyle) -> CGImage? {
        let w = CGFloat(base.width)
        let h = CGFloat(base.height)
        let minDim = min(w, h)
        let pad = (minDim * style.paddingFraction).rounded()
        let outW = Int(w + 2 * pad)
        let outH = Int(h + 2 * pad)
        guard outW > 0, outH > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let full = CGRect(x: 0, y: 0, width: outW, height: outH)
        drawBackground(style.background, in: ctx, rect: full)

        let imageRect = CGRect(x: pad, y: pad, width: w, height: h)
        let radius = minDim * style.cornerFraction
        let rounded = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if style.shadow {
            ctx.saveGState()
            let blur = max(1, minDim * style.shadowFraction)
            ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.addPath(rounded)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()
        ctx.draw(base, in: imageRect)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private static func drawBackground(_ fill: BackgroundFill, in ctx: CGContext, rect: CGRect) {
        switch fill {
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .gradient(let colors, let angle):
            let cgColors = colors.map { ($0.usingColorSpace(.sRGB) ?? $0).cgColor } as CFArray
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: nil) else {
                ctx.setFillColor(colors.first?.cgColor ?? NSColor.black.cgColor)
                ctx.fill(rect)
                return
            }
            let radians = angle * .pi / 180
            let dx = cos(radians), dy = sin(radians)
            let start = CGPoint(x: rect.midX - dx * rect.width / 2, y: rect.midY - dy * rect.height / 2)
            let end = CGPoint(x: rect.midX + dx * rect.width / 2, y: rect.midY + dy * rect.height / 2)
            ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }
}
