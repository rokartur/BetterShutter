import AppKit

/// How the area behind a beautified screenshot is filled.
@MainActor
enum BackgroundFill {
    case solid(NSColor)
    case gradient([NSColor], angleDegrees: CGFloat)
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

/// The full beautify configuration. Padding / corner / shadow are fractions of the image's
/// smaller side so the look is resolution-independent.
@MainActor
struct BeautifyStyle {
    var background: BackgroundFill
    var paddingFraction: CGFloat
    var cornerFraction: CGFloat
    var shadow: Bool
    var shadowFraction: CGFloat

    static func makeDefault() -> BeautifyStyle {
        BeautifyStyle(
            background: BackgroundPreset.all[0].fill,
            paddingFraction: 0.08,
            cornerFraction: 0.03,
            shadow: true,
            shadowFraction: 0.05
        )
    }
}
