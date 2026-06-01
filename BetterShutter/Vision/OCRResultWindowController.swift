import AppKit

/// Shows OCR results in a glass window: selectable recognized text with a "Preserve line breaks"
/// toggle and Copy, plus any detected QR/barcode payloads with Copy / Open actions.
@MainActor
final class OCRResultWindowController: NSObject, NSWindowDelegate {
    static let shared = OCRResultWindowController()

    private var window: NSWindow?
    private let textView = NSTextView()
    private let preserve = NSButton(checkboxWithTitle: "Preserve line breaks", target: nil, action: nil)
    private var barcodeStack: NSStackView?
    private var rawText = ""
    private var barcodes: [String] = []

    func show(text: String, barcodes: [String]) {
        rawText = text
        self.barcodes = barcodes
        if window == nil { build() }
        preserve.state = .on
        renderText()
        rebuildBarcodes()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Build

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Recognized Text"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()

        let glass = GlassPanelView(cornerRadius: 0)
        window.contentView = glass
        let content = glass.contentView

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = textView
        content.addSubview(scroll)

        preserve.target = self
        preserve.action = #selector(togglePreserve)
        preserve.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preserve)

        let copy = NSButton(title: "Copy Text", target: self, action: #selector(copyText))
        copy.bezelStyle = .rounded
        copy.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(copy)

        let barcodeStack = NSStackView()
        barcodeStack.orientation = .vertical
        barcodeStack.alignment = .leading
        barcodeStack.spacing = 4
        barcodeStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(barcodeStack)
        self.barcodeStack = barcodeStack

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            barcodeStack.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            barcodeStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            barcodeStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            preserve.topAnchor.constraint(equalTo: barcodeStack.bottomAnchor, constant: 10),
            preserve.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            preserve.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            copy.centerYAnchor.constraint(equalTo: preserve.centerYAnchor),
            copy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
        ])
        self.window = window
    }

    // MARK: Render

    private var displayedText: String {
        preserve.state == .on ? rawText : rawText.replacingOccurrences(of: "\n", with: " ")
    }

    private func renderText() {
        textView.string = displayedText
    }

    private func rebuildBarcodes() {
        guard let stack = barcodeStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for payload in barcodes {
            let row = NSStackView()
            row.spacing = 6
            let label = NSTextField(labelWithString: "QR: \(payload)")
            label.lineBreakMode = .byTruncatingMiddle
            label.font = .systemFont(ofSize: 11)
            row.addArrangedSubview(label)
            let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyBarcode(_:)))
            copyButton.controlSize = .small
            copyButton.bezelStyle = .accessoryBarAction
            copyButton.tag = barcodes.firstIndex(of: payload) ?? 0
            row.addArrangedSubview(copyButton)
            if let url = URL(string: payload), url.scheme != nil {
                let open = NSButton(title: "Open", target: self, action: #selector(openBarcode(_:)))
                open.controlSize = .small
                open.bezelStyle = .accessoryBarAction
                open.tag = copyButton.tag
                row.addArrangedSubview(open)
            }
            stack.addArrangedSubview(row)
        }
    }

    // MARK: Actions

    @objc private func togglePreserve() { renderText() }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedText, forType: .string)
        HUD.show("Copied")
    }

    @objc private func copyBarcode(_ sender: NSButton) {
        guard barcodes.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(barcodes[sender.tag], forType: .string)
        HUD.show("Copied")
    }

    @objc private func openBarcode(_ sender: NSButton) {
        guard barcodes.indices.contains(sender.tag), let url = URL(string: barcodes[sender.tag]) else { return }
        NSWorkspace.shared.open(url)
    }
}
