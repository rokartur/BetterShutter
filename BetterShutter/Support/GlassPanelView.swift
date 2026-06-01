import AppKit

/// A rounded "liquid glass" backdrop that hosts content. On macOS 26+ (Tahoe) it uses the real
/// `NSGlassEffectView`; on earlier systems it falls back to a frosted `NSVisualEffectView` so the
/// app still looks right everywhere. Add your subviews to `contentView` — never to the panel itself.
///
/// Single source of truth for the app's glass look: every floating chrome (capture toolbar, float
/// preview, HUD, recording bar, capture browser) is built on this so the material stays consistent.
@MainActor
final class GlassPanelView: NSView {

    /// Put content here. It sits above the glass/vibrancy backdrop and is clipped to the corners.
    let contentView = NSView()

    init(cornerRadius: CGFloat = 14, tint: NSColor? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            if let tint { glass.tintColor = tint }
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = contentView      // glass lays this out to fill itself
            addSubview(glass)
            Self.pin(glass, to: self)
        } else {
            let vibrancy = NSVisualEffectView()
            vibrancy.material = .hudWindow
            vibrancy.blendingMode = .behindWindow
            vibrancy.state = .active
            vibrancy.translatesAutoresizingMaskIntoConstraints = false
            vibrancy.wantsLayer = true
            vibrancy.layer?.cornerRadius = cornerRadius
            vibrancy.layer?.cornerCurve = .continuous
            vibrancy.layer?.masksToBounds = true
            addSubview(vibrancy)
            Self.pin(vibrancy, to: self)

            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
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

extension NSPanel {
    /// Builds a borderless, non-activating, transparent floating panel — the standard host for the
    /// app's glass chrome. The rounded glass content defines the visible shape (and its shadow).
    @MainActor
    static func glassChrome(size: NSSize, level: NSWindow.Level = .floating) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}
