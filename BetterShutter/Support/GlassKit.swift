import AppKit

/// Reusable Liquid Glass building blocks layered on top of `GlassPanelView` (the panel primitive).
///
/// Everything here is Liquid-Glass-first with a graceful pre-macOS-26 fallback, and every component
/// returns the *same* Swift type from both branches so call sites stay branch-agnostic.

/// Groups several glass pills so they meld fluidly when close together. On macOS 26 this is a real
/// `NSGlassEffectContainerView` (which also batches their rendering); below 26 it is an inert
/// passthrough — visual continuity then comes from each child's own `GlassPanelView`/glass backing.
///
/// Add your glass children to `contentView`.
@MainActor
final class GlassContainerView: NSView {

    /// Host for the glass pills you want merged. Fills the container.
    let contentView = NSView()

    init(spacing: CGFloat = GlassTokens.Space.glassMerge) {
        super.init(frame: .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.spacing = spacing
            container.contentView = contentView
            container.translatesAutoresizingMaskIntoConstraints = false
            addSubview(container)
            Self.pin(container, to: self)
        } else {
            addSubview(contentView)
            Self.pin(contentView, to: self)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func pin(_ view: NSView, to host: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}

/// Builds the app's standard glass icon button. Use this everywhere a borderless symbol button used
/// to be hand-rolled (capture action bar, float-preview toolbar, editor/beautify actions).
@MainActor
enum GlassIconButton {

    /// - Parameters:
    ///   - standalone: `true` when the button floats on its own (e.g. the float-preview dismiss "x")
    ///     and must carry its own glass pill. `false` when it lives inside a `GlassContainerView` or
    ///     `NSToolbar` that already supplies the shared glass — the common case.
    ///
    /// Returns an `NSView` in both the macOS 26 and the fallback path. The returned view is sized by
    /// the caller (frame- or constraint-based); any inner button fills it.
    static func make(symbol: String,
                     tooltip: String,
                     target: AnyObject?,
                     action: Selector,
                     pointSize: CGFloat = 13,
                     standalone: Bool = false) -> NSView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(GlassTokens.symbol(pointSize))
        let button = NSButton(image: image ?? NSImage(), target: target, action: action)
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)

        if #available(macOS 26.0, *) {
            // The glass bezel already renders an individual glass pill, and adjacent ones merge
            // automatically inside a container/toolbar — so `standalone` needs no extra wrapper.
            button.isBordered = true
            button.bezelStyle = .glass
            return button
        } else {
            // Pre-26 fallback: the previous borderless + rounded-layer look.
            button.isBordered = false
            button.bezelStyle = .smallSquare
            button.contentTintColor = .labelColor
            button.wantsLayer = true
            button.layer?.cornerRadius = GlassTokens.Radius.control
            guard standalone else { return button }

            let host = GlassPanelView(cornerRadius: GlassTokens.Radius.pill)
            button.translatesAutoresizingMaskIntoConstraints = false
            host.contentView.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: host.contentView.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: host.contentView.trailingAnchor),
                button.topAnchor.constraint(equalTo: host.contentView.topAnchor),
                button.bottomAnchor.constraint(equalTo: host.contentView.bottomAnchor),
            ])
            return host
        }
    }
}
