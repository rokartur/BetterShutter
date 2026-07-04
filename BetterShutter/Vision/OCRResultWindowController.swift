import AppKit
import SwiftUI

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
        // The controller keeps this window across close/reopen; without this AppKit would release
        // it on close and the next show() would message a dangling pointer (unrecognized selector).
        window.isReleasedWhenClosed = false
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

        var translateButton: NSButton?
        if #available(macOS 15.0, *) {
            let translate = NSButton(title: "Translate", target: self, action: #selector(translateText))
            translate.bezelStyle = .rounded
            translate.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(translate)
            translateButton = translate
        }

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
        if let translateButton {
            NSLayoutConstraint.activate([
                translateButton.centerYAnchor.constraint(equalTo: preserve.centerYAnchor),
                translateButton.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -8),
            ])
        }
        self.window = window
    }

    @available(macOS 15.0, *)
    @objc private func translateText() {
        guard let window, !rawText.isEmpty else { return }
        // Don't capture the sheet window in its own content view's closure — that retain cycle
        // (sheet → hosting controller → view → closure → sheet) leaked a window per Translate.
        let view = OCRTranslationView(sourceText: rawText) { [weak window] in
            guard let window, let sheet = window.attachedSheet else { return }
            window.endSheet(sheet)
        }
        let host = NSHostingController(rootView: view)
        let sheetWindow = NSWindow(contentViewController: host)
        sheetWindow.setContentSize(NSSize(width: 440, height: 320))
        window.beginSheet(sheetWindow)
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
            if Self.webURL(payload) != nil {
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
        // Only ever open http/https from a QR payload — never file:// or custom app schemes that a
        // malicious code could use to trigger actions.
        guard barcodes.indices.contains(sender.tag), let url = Self.webURL(barcodes[sender.tag]) else { return }
        NSWorkspace.shared.open(url)
    }

    /// A URL only if `payload` is an http/https web address; nil otherwise.
    private static func webURL(_ payload: String) -> URL? {
        guard let url = URL(string: payload), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
