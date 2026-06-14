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
        let barHeight = style.windowFrame == .none ? 0 : max(24, (minDim * 0.05).rounded())
        let baseW = Int(w + 2 * pad)
        let baseH = Int(h + barHeight + 2 * pad)
        guard baseW > 0, baseH > 0 else { return nil }

        // Optionally enlarge the canvas to hit a target aspect ratio, centering the card.
        var outW = baseW, outH = baseH
        if let aspect = style.targetAspect, aspect > 0 {
            let current = CGFloat(baseW) / CGFloat(baseH)
            if current < aspect {
                outW = Int((CGFloat(baseH) * aspect).rounded())
            } else if current > aspect {
                outH = Int((CGFloat(baseW) / aspect).rounded())
            }
        }
        let offsetX = CGFloat((outW - baseW) / 2)
        let offsetY = CGFloat((outH - baseH) / 2)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let full = CGRect(x: 0, y: 0, width: outW, height: outH)
        drawBackground(style.background, in: ctx, rect: full)

        // Bottom-left coords: image sits at the bottom of the card, chrome bar above it.
        let cardRect = CGRect(x: pad + offsetX, y: pad + offsetY, width: w, height: h + barHeight)
        let imageRect = CGRect(x: pad + offsetX, y: pad + offsetY, width: w, height: h)
        let radius = minDim * style.cornerFraction
        let rounded = CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

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
        if style.windowFrame != .none {
            let barColor = style.windowFrame == .dark
                ? NSColor(calibratedWhite: 0.17, alpha: 1)
                : NSColor(calibratedWhite: 0.93, alpha: 1)
            ctx.setFillColor(barColor.cgColor)
            ctx.fill(cardRect)
            let barRect = CGRect(x: pad + offsetX, y: pad + offsetY + h, width: w, height: barHeight)
            drawTrafficLights(in: ctx, barRect: barRect)
        }
        ctx.draw(base, in: imageRect)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    /// Mesh gradient: fill with the first color, then blend soft radial blobs of each color at
    /// scattered anchors. Pure CoreGraphics, so it renders identically on every macOS version.
    private static func drawMesh(_ colors: [NSColor], in ctx: CGContext, rect: CGRect) {
        guard let base = colors.first else { return }
        ctx.setFillColor((base.usingColorSpace(.sRGB) ?? base).cgColor)
        ctx.fill(rect)
        let anchors = [
            CGPoint(x: 0.18, y: 0.22), CGPoint(x: 0.82, y: 0.18),
            CGPoint(x: 0.80, y: 0.82), CGPoint(x: 0.20, y: 0.80), CGPoint(x: 0.5, y: 0.5),
        ]
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let radius = max(rect.width, rect.height) * 0.78
        for (index, color) in colors.enumerated() {
            let a = anchors[index % anchors.count]
            let center = CGPoint(x: rect.minX + rect.width * a.x, y: rect.minY + rect.height * a.y)
            let c = color.usingColorSpace(.sRGB) ?? color
            let cgColors = [c.withAlphaComponent(0.95).cgColor, c.withAlphaComponent(0).cgColor] as CFArray
            guard let g = CGGradient(colorsSpace: space, colors: cgColors, locations: [0, 1]) else { continue }
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius, options: [])
        }
    }

    private static func drawTrafficLights(in ctx: CGContext, barRect: CGRect) {
        let r = max(4, barRect.height * 0.16)
        let gap = r * 2.8
        let cy = barRect.midY
        let colors = [BackgroundPreset.hex(0xFF5F57), BackgroundPreset.hex(0xFEBC2E), BackgroundPreset.hex(0x28C840)]
        for (index, color) in colors.enumerated() {
            let cx = barRect.minX + barRect.height * 0.9 + CGFloat(index) * gap
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        }
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
        case .mesh(let colors):
            drawMesh(colors, in: ctx, rect: rect)
        case .image(let cg):
            // Aspect-fill the custom image into the background rect.
            let imageAspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
            let rectAspect = rect.width / max(rect.height, 1)
            let drawRect: CGRect
            if imageAspect > rectAspect {
                let w = rect.height * imageAspect
                drawRect = CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: rect.height)
            } else {
                let h = rect.width / imageAspect
                drawRect = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
            }
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.draw(cg, in: drawRect)
            ctx.restoreGState()
        }
    }
}
