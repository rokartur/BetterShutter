import AppKit

/// What the user chose to do with a confirmed region selection. Surfaced by the CleanShot-style
/// action bar that floats next to the selection, and threaded back to `CaptureCoordinator`.
enum OverlayAction: Sendable {
    case capture    // run the configured after-capture action (copy / preview)
    case annotate   // open the annotation editor
    case copy       // copy to the clipboard only
    case save       // save a file only
    case record     // start recording just this region

    fileprivate var symbol: String {
        switch self {
        case .capture: return "checkmark.circle.fill"
        case .annotate: return "pencil.tip.crop.circle"
        case .copy: return "doc.on.doc"
        case .save: return "arrow.down.circle"
        case .record: return "record.circle"
        }
    }

    fileprivate var tooltip: String {
        switch self {
        case .capture: return "Capture (↩)"
        case .annotate: return "Annotate"
        case .copy: return "Copy"
        case .save: return "Save"
        case .record: return "Record region"
        }
    }
}

/// The floating, liquid-glass action bar shown beside a pending selection — the signature
/// CleanShot-X element. Icon buttons for capture / annotate / copy / save / record plus a cancel,
/// laid out left-to-right. Sizes itself deterministically so the overlay can position it by frame.
@MainActor
final class CaptureActionBar: NSView {

    var onAction: ((OverlayAction) -> Void)?
    var onCancel: (() -> Void)?

    private static let button: CGFloat = 34
    private static let gap: CGFloat = 3
    private static let inset: CGFloat = 7
    static let height: CGFloat = button + inset * 2

    static func width(for actions: [OverlayAction]) -> CGFloat {
        let count = actions.count + 1 // + cancel
        return CGFloat(count) * button + CGFloat(max(0, count - 1)) * gap + inset * 2 + separatorSlot
    }
    private static let separatorSlot: CGFloat = 9

    init(actions: [OverlayAction]) {
        let size = NSSize(width: Self.width(for: actions), height: Self.height)
        super.init(frame: NSRect(origin: .zero, size: size))

        let glass = GlassPanelView(cornerRadius: 13)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        var x = Self.inset
        for action in actions {
            let b = makeButton(symbol: action.symbol, tooltip: action.tooltip)
            b.tag = Self.tag(for: action)
            b.target = self
            b.action = #selector(actionTapped(_:))
            b.frame = NSRect(x: x, y: Self.inset, width: Self.button, height: Self.button)
            glass.contentView.addSubview(b)
            x += Self.button + Self.gap
        }

        // Faint separator before the cancel button.
        x += Self.separatorSlot - Self.gap
        let sep = NSView(frame: NSRect(x: x - Self.separatorSlot / 2, y: Self.inset + 5, width: 1, height: Self.button - 10))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        glass.contentView.addSubview(sep)

        let cancel = makeButton(symbol: "xmark", tooltip: "Cancel (esc)")
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        cancel.contentTintColor = .secondaryLabelColor
        cancel.frame = NSRect(x: x, y: Self.inset, width: Self.button, height: Self.button)
        glass.contentView.addSubview(cancel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeButton(symbol: String, tooltip: String) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .smallSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.toolTip = tooltip
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        return button
    }

    // OverlayAction isn't @objc-representable, so map via integer tags.
    private static func tag(for action: OverlayAction) -> Int {
        switch action {
        case .capture: return 0
        case .annotate: return 1
        case .copy: return 2
        case .save: return 3
        case .record: return 4
        }
    }
    private static func action(for tag: Int) -> OverlayAction {
        switch tag {
        case 1: return .annotate
        case 2: return .copy
        case 3: return .save
        case 4: return .record
        default: return .capture
        }
    }

    @objc private func actionTapped(_ sender: NSButton) {
        onAction?(Self.action(for: sender.tag))
    }

    @objc private func cancelTapped() { onCancel?() }
}
