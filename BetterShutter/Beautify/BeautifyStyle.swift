import AppKit

/// How the area behind a beautified screenshot is filled.
@MainActor
enum BackgroundFill {
    case solid(NSColor)
    case gradient([NSColor], angleDegrees: CGFloat)
    /// Soft multi-color mesh — several radial color blobs blended over a base (macshot-style).
    case mesh([NSColor])
    case image(CGImage)
}

/// A named background option shown in the beautify picker.
@MainActor
struct BackgroundPreset: Identifiable {
    let id: String
    let name: String
    let fill: BackgroundFill

    static let all: [BackgroundPreset] = [
        BackgroundPreset(id: "sunset", name: "Sunset",
                         fill: .gradient([hex(0xFF6CAB), hex(0x7366FF)], angleDegrees: 45)),
        BackgroundPreset(id: "ocean", name: "Ocean",
                         fill: .gradient([hex(0x2BC0E4), hex(0x1A2980)], angleDegrees: 45)),
        BackgroundPreset(id: "mango", name: "Mango",
                         fill: .gradient([hex(0xFFE259), hex(0xFFA751)], angleDegrees: 45)),
        BackgroundPreset(id: "mint", name: "Mint",
                         fill: .gradient([hex(0x11998E), hex(0x38EF7D)], angleDegrees: 45)),
        BackgroundPreset(id: "grape", name: "Grape",
                         fill: .gradient([hex(0x8E2DE2), hex(0x4A00E0)], angleDegrees: 45)),
        BackgroundPreset(id: "peach", name: "Peach",
                         fill: .gradient([hex(0xFFB199), hex(0xFF0844)], angleDegrees: 45)),
        BackgroundPreset(id: "slate", name: "Slate",
                         fill: .gradient([hex(0x434343), hex(0x000000)], angleDegrees: 90)),
        BackgroundPreset(id: "paper", name: "Paper",
                         fill: .solid(hex(0xF2F2F7))),
        BackgroundPreset(id: "aurora", name: "Aurora",
                         fill: .gradient([hex(0x00C9FF), hex(0x92FE9D)], angleDegrees: 60)),
        BackgroundPreset(id: "candy", name: "Candy",
                         fill: .gradient([hex(0xFC5C7D), hex(0x6A82FB)], angleDegrees: 45)),
        BackgroundPreset(id: "ember", name: "Ember",
                         fill: .gradient([hex(0xF12711), hex(0xF5AF19)], angleDegrees: 45)),
        BackgroundPreset(id: "twilight", name: "Twilight",
                         fill: .gradient([hex(0x0F2027), hex(0x2C5364)], angleDegrees: 60)),
        BackgroundPreset(id: "blossom", name: "Blossom",
                         fill: .gradient([hex(0xFFDEE9), hex(0xB5FFFC)], angleDegrees: 30)),
        BackgroundPreset(id: "graphite", name: "Graphite",
                         fill: .solid(hex(0x1C1C1E))),
        // More linear gradients.
        BackgroundPreset(id: "lavender", name: "Lavender",
                         fill: .gradient([hex(0xC471F5), hex(0xFA71CD)], angleDegrees: 45)),
        BackgroundPreset(id: "lagoon", name: "Lagoon",
                         fill: .gradient([hex(0x43E97B), hex(0x38F9D7)], angleDegrees: 45)),
        BackgroundPreset(id: "dusk", name: "Dusk",
                         fill: .gradient([hex(0x4B6CB7), hex(0x182848)], angleDegrees: 60)),
        BackgroundPreset(id: "flare", name: "Flare",
                         fill: .gradient([hex(0xF83600), hex(0xFE8C00)], angleDegrees: 45)),
        BackgroundPreset(id: "royal", name: "Royal",
                         fill: .gradient([hex(0x141E30), hex(0x243B55)], angleDegrees: 60)),
        BackgroundPreset(id: "bubblegum", name: "Bubblegum",
                         fill: .gradient([hex(0xFF9A9E), hex(0xFAD0C4)], angleDegrees: 30)),
        BackgroundPreset(id: "forest", name: "Forest",
                         fill: .gradient([hex(0x134E5E), hex(0x71B280)], angleDegrees: 45)),
        BackgroundPreset(id: "plum", name: "Plum",
                         fill: .gradient([hex(0x614385), hex(0x516395)], angleDegrees: 60)),
        BackgroundPreset(id: "coral", name: "Coral",
                         fill: .gradient([hex(0xFF7E5F), hex(0xFEB47B)], angleDegrees: 45)),
        BackgroundPreset(id: "sky", name: "Sky",
                         fill: .gradient([hex(0x56CCF2), hex(0x2F80ED)], angleDegrees: 60)),
        BackgroundPreset(id: "snow", name: "Snow",
                         fill: .solid(hex(0xFFFFFF))),
        // Mesh gradients (multi-blob).
        BackgroundPreset(id: "mesh-nebula", name: "Nebula",
                         fill: .mesh([hex(0x4158D0), hex(0xC850C0), hex(0xFFCC70), hex(0x2A2A72)])),
        BackgroundPreset(id: "mesh-pastel", name: "Pastel Mesh",
                         fill: .mesh([hex(0xA9C9FF), hex(0xFFBBEC), hex(0xC2FFD8), hex(0xFFF3B0)])),
        BackgroundPreset(id: "mesh-sunrise", name: "Sunrise Mesh",
                         fill: .mesh([hex(0xFF3CAC), hex(0x784BA0), hex(0x2B86C5), hex(0xFFB75E)])),
        BackgroundPreset(id: "mesh-aurora", name: "Aurora Mesh",
                         fill: .mesh([hex(0x00DBDE), hex(0xFC00FF), hex(0x00C9FF), hex(0x92FE9D)])),
        BackgroundPreset(id: "mesh-ember", name: "Ember Mesh",
                         fill: .mesh([hex(0xF12711), hex(0xF5AF19), hex(0xFF512F), hex(0xDD2476)])),
        BackgroundPreset(id: "mesh-mint", name: "Mint Mesh",
                         fill: .mesh([hex(0x11998E), hex(0x38EF7D), hex(0x56CCF2), hex(0xC2FFD8)])),
    ]

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Optional 3D perspective tilt applied to the screenshot card for a mockup look.
enum BeautifyPerspective: Int, CaseIterable, Sendable {
    case none
    case left
    case right

    var presentableName: String {
        switch self {
        case .none: return "Flat"
        case .left: return "Tilt Left"
        case .right: return "Tilt Right"
        }
    }
}

/// Optional macOS window-chrome mockup drawn above the screenshot.
enum WindowFrame: Int, CaseIterable, Sendable {
    case none
    case light
    case dark

    var presentableName: String {
        switch self {
        case .none: return "No Frame"
        case .light: return "Light Frame"
        case .dark: return "Dark Frame"
        }
    }
}

/// The full beautify configuration. Padding / corner / shadow are fractions of the image's
/// smaller side so the look is resolution-independent.
@MainActor
struct BeautifyStyle {
    var background: BackgroundFill
    var paddingFraction: CGFloat
    var cornerFraction: CGFloat
    var shadow: Bool
    var shadowFraction: CGFloat
    var windowFrame: WindowFrame
    /// Output aspect ratio (width / height). Nil keeps the natural padded size; otherwise the canvas
    /// is enlarged on one axis and the card centered ("auto-balanced" composition).
    var targetAspect: CGFloat?
    /// 3D tilt applied to the card (Snapzy-style mockup). `.none` keeps it flat.
    var perspective: BeautifyPerspective

    static func makeDefault() -> BeautifyStyle {
        BeautifyStyle(
            background: BackgroundPreset.all[0].fill,
            paddingFraction: 0.08,
            cornerFraction: 0.03,
            shadow: true,
            shadowFraction: 0.05,
            windowFrame: .none,
            targetAspect: nil,
            perspective: .none
        )
    }
}
