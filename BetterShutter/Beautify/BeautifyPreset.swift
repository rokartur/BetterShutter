import AppKit

/// A serializable background fill. Image fills are never persisted (they reference local files we'd
/// need security-scoped bookmarks for), so converting an `.image` background yields `nil`.
nonisolated enum CodableBackgroundFill: Codable, Sendable {
    case solid(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
    case gradient(colors: [[CGFloat]], angle: CGFloat)
    case mesh(colors: [[CGFloat]])
}

/// A persisted, named beautify configuration the user re-applies with one click. Stored as JSON in
/// `Preferences`. A preset captured while an image background is active records no background and
/// leaves the current one untouched on apply.
nonisolated struct BeautifyPreset: Codable, Identifiable, Sendable {
    var name: String
    /// `nil` means "don't change the background when applying" (image backgrounds aren't stored).
    var background: CodableBackgroundFill?
    var paddingFraction: CGFloat
    var cornerFraction: CGFloat
    var shadow: Bool
    var shadowFraction: CGFloat
    var windowFrame: Int
    var targetAspect: CGFloat?

    var id: String { name }
}

@MainActor
extension CodableBackgroundFill {
    init?(_ fill: BackgroundFill) {
        switch fill {
        case .solid(let color):
            guard let s = color.usingColorSpace(.sRGB) else { return nil }
            self = .solid(r: s.redComponent, g: s.greenComponent, b: s.blueComponent, a: s.alphaComponent)
        case .gradient(let colors, let angle):
            let comps = colors.compactMap { $0.usingColorSpace(.sRGB) }
                .map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] }
            guard !comps.isEmpty else { return nil }
            self = .gradient(colors: comps, angle: angle)
        case .mesh(let colors):
            let comps = colors.compactMap { $0.usingColorSpace(.sRGB) }
                .map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] }
            guard !comps.isEmpty else { return nil }
            self = .mesh(colors: comps)
        case .image:
            return nil
        }
    }

    var fill: BackgroundFill {
        func color(_ c: [CGFloat]) -> NSColor {
            NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1)
        }
        switch self {
        case .solid(let r, let g, let b, let a):
            return .solid(NSColor(srgbRed: r, green: g, blue: b, alpha: a))
        case .gradient(let colors, let angle):
            return .gradient(colors.map(color), angleDegrees: angle)
        case .mesh(let colors):
            return .mesh(colors.map(color))
        }
    }
}

@MainActor
extension BeautifyPreset {
    init(name: String, style: BeautifyStyle) {
        self.name = name
        self.background = CodableBackgroundFill(style.background)
        self.paddingFraction = style.paddingFraction
        self.cornerFraction = style.cornerFraction
        self.shadow = style.shadow
        self.shadowFraction = style.shadowFraction
        self.windowFrame = style.windowFrame.rawValue
        self.targetAspect = style.targetAspect
    }

    /// A copy of `style` with this preset's parameters applied. The background is replaced only when
    /// the preset stored one; image-background presets keep the current background.
    func applied(to style: BeautifyStyle) -> BeautifyStyle {
        var s = style
        if let fill = background?.fill { s.background = fill }
        s.paddingFraction = paddingFraction
        s.cornerFraction = cornerFraction
        s.shadow = shadow
        s.shadowFraction = shadowFraction
        s.windowFrame = WindowFrame(rawValue: windowFrame) ?? .none
        s.targetAspect = targetAspect
        return s
    }
}
