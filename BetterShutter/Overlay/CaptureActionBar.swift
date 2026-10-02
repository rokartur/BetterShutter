import AppKit

/// The capture mode picked from the All-in-One bar under a pending selection, threaded back to
/// `CaptureCoordinator`. Order and labels follow CleanShot X 5.0.1.
enum OverlayAction: Int, CaseIterable, Sendable {
    case area, fullscreen, window, scrolling, timer, ocr, recording

    fileprivate var symbol: String {
        switch self {
        case .area: return "viewfinder"
        case .fullscreen: return "display"
        case .window: return "macwindow"
        case .scrolling: return "arrow.down"
        case .timer: return "timer"
        case .ocr: return "textformat"
        case .recording: return "video"
        }
    }

    fileprivate var title: String {
        switch self {
        case .area: return "Area"
        case .fullscreen: return "Fullscreen"
        case .window: return "Window"
        case .scrolling: return "Scrolling"
        case .timer: return "Timer"
        case .ocr: return "OCR"
        case .recording: return "Recording"
        }
    }

    /// OCR and Recording sit in their own groups, split by a hairline.
    fileprivate var startsGroup: Bool { self == .ocr || self == .recording }
}

/// CleanShot X's All-in-One bar: a mode strip (icon over label) and a size readout, as two dark
/// rounded groups side by side. Sizes itself deterministically so the overlay can position it by frame.
@MainActor
final class CaptureActionBar: NSView {
    var onAction: ((OverlayAction) -> Void)?

    private let widthLabel = NSTextField(labelWithString: "0")
    private let heightLabel = NSTextField(labelWithString: "0")

    private static let height: CGFloat = 52
    private static let modeWidth: CGFloat = 62.5
    private static let modeInset: CGFloat = 5
    private static let groupGap: CGFloat = 15
    private static let fieldSize = NSSize(width: 44, height: 25)
    private static let sizeGroupWidth: CGFloat = 132

    init(actions: [OverlayAction]) {
        let modesWidth = CGFloat(actions.count) * Self.modeWidth + Self.modeInset * 2
        let size = NSSize(width: modesWidth + Self.groupGap + Self.sizeGroupWidth, height: Self.height)
        super.init(frame: NSRect(origin: .zero, size: size))

        let modes = Self.group(width: modesWidth)
        addSubview(modes)
        var x = Self.modeInset
        for action in actions {
            if action.startsGroup {
                modes.addSubview(Self.separator(x: x, height: Self.height))
            }
            let button = modeButton(action)
            button.frame = NSRect(x: x, y: 0, width: Self.modeWidth, height: Self.height)
            modes.addSubview(button)
            x += Self.modeWidth
        }

        let sizeGroup = Self.group(width: Self.sizeGroupWidth)
        sizeGroup.frame.origin.x = modesWidth + Self.groupGap
        addSubview(sizeGroup)
        let times = NSTextField(labelWithString: "\u{00D7}")
        times.font = .systemFont(ofSize: 13, weight: .semibold)
        times.textColor = .white
        let stack = NSStackView(views: [field(widthLabel), times, field(heightLabel)])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        sizeGroup.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: sizeGroup.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: sizeGroup.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Selection size in points, shown in the W × H readout.
    func showSelectionSize(_ size: CGSize) {
        widthLabel.stringValue = String(Int(size.width.rounded()))
        heightLabel.stringValue = String(Int(size.height.rounded()))
    }

    private static func group(width: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.96).cgColor
        view.layer?.cornerRadius = 12
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        return view
    }

    private static func separator(x: CGFloat, height: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: x, y: 12, width: 1, height: height - 24))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        return view
    }

    private func field(_ label: NSTextField) -> NSView {
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        box.layer?.cornerRadius = 7
        box.layer?.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: Self.fieldSize.width),
            box.heightAnchor.constraint(equalToConstant: Self.fieldSize.height),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    /// Icon over label, laid out by hand: NSButton's `.imageAbove` packs the two into an overlap.
    private func modeButton(_ action: OverlayAction) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(GlassTokens.symbol(16, .medium))!)
        icon.contentTintColor = .white
        let label = NSTextField(labelWithString: action.title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(white: 0.75, alpha: 1)
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: "", target: self, action: #selector(modeTapped(_:)))
        button.tag = action.rawValue
        button.isBordered = false
        button.setAccessibilityLabel(action.title)
        button.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        return button
    }

    @objc private func modeTapped(_ sender: NSButton) {
        guard let action = OverlayAction(rawValue: sender.tag) else { return }
        onAction?(action)
    }
}
