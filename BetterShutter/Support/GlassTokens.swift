import AppKit

/// Single source of truth for the Liquid Glass restyle: the corner-radius / spacing scales, symbol
/// configs, glass defaults, and the semantic *dynamic* colors that flip with the system appearance.
///
/// These replace the ~dozen hardcoded `NSColor.black/white.withAlphaComponent(...)` values that used
/// to be scattered across the floating chrome (and which only ever looked right in Dark mode).
///
/// - Important: a dynamic `NSColor` loses its adaptivity the instant it is baked into a CALayer
///   `.cgColor`. Layer-backed chrome must re-resolve in `viewDidChangeEffectiveAppearance()` — use
///   `GlassTokens.cg(_:for:)` for that.
@MainActor
enum GlassTokens {

    // MARK: Corner radii (always paired with `.continuous` curve)

    enum Radius {
        static let pill: CGFloat = 999    // capsule — a lone icon button on its own glass
        static let card: CGFloat = 14     // float-preview card / panels (matches prior 14)
        static let bar: CGFloat = 13      // action bars (matches CaptureActionBar's 13)
        static let control: CGFloat = 7   // inner icon-button hit target (matches prior 7)
    }

    // MARK: Spacing

    enum Space {
        static let glassMerge: CGFloat = 8   // NSGlassEffectContainerView.spacing for adjacent pills
        static let barInset: CGFloat = 7
        static let itemGap: CGFloat = 6
    }

    // MARK: Symbol / font

    static func symbol(_ pointSize: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    }

    // MARK: Glass defaults

    /// nil tint keeps the neutral, system-default ("regular") glass material — the locked decision.
    static let glassTint: NSColor? = nil

    // MARK: Dynamic semantic colors (re-resolve per effective appearance)

    /// Letterbox backing behind a thumbnail. Was `NSColor.black.withAlphaComponent(0.55)`.
    static let cardBacking = dynamic(light: .black.withAlphaComponent(0.45),
                                     dark: .black.withAlphaComponent(0.55))
    /// Hairline separating chrome from the desktop. Was white .16 / .18 / .25.
    static let hairline = dynamic(light: .black.withAlphaComponent(0.12),
                                  dark: .white.withAlphaComponent(0.16))
    /// In-bar separator (CaptureActionBar). Was `white.withAlphaComponent(0.18)`.
    static let separator = dynamic(light: .black.withAlphaComponent(0.10),
                                   dark: .white.withAlphaComponent(0.18))
    /// Dark end of the scrim gradient under a card's hover toolbar. Was black .5 / .55.
    static let scrimBottom = dynamic(light: .black.withAlphaComponent(0.50),
                                     dark: .black.withAlphaComponent(0.55))
    /// Pin-window border. Was `white.withAlphaComponent(0.25)`.
    static let pinBorder = dynamic(light: .black.withAlphaComponent(0.18),
                                   dark: .white.withAlphaComponent(0.25))

    // MARK: Fixed (non-adaptive) chrome

    /// Chrome that must NOT follow the system appearance: the recording overlays are burned into the
    /// captured video, and the capture dimension pill sits over the always-dark capture dim. Flipping
    /// these to a light variant would make their white text/strokes illegible. Centralized here only
    /// for a single source of truth — the values are unchanged from before the restyle.
    enum Fixed {
        static let keystrokePill = NSColor.black.withAlphaComponent(0.75)
        static let webcamBorder = NSColor.white.withAlphaComponent(0.9)
        static let clickRingFill = NSColor.systemYellow.withAlphaComponent(0.30)
        static let clickRingStroke = NSColor.systemYellow
        static let dimensionPill = NSColor.black.withAlphaComponent(0.65)
        static let swatchStroke = NSColor.black.withAlphaComponent(0.2)
    }

    // MARK: Helpers

    /// Builds a color that re-evaluates per appearance. Works without an asset catalog (the app is
    /// 100% programmatic), so it's the right tool for a code-only theme.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Resolves a (possibly dynamic) color to a `CGColor` for `view`'s current effective appearance.
    /// Call from `viewDidChangeEffectiveAppearance()` when feeding a CALayer, since `cgColor` is
    /// captured at assignment time and won't follow later appearance changes on its own.
    static func cg(_ color: NSColor, for view: NSView) -> CGColor {
        var resolved = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}
