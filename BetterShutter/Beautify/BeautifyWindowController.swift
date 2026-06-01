import AppKit
import UniformTypeIdentifiers

/// Beautify editor: drop a screenshot onto a gradient/solid background with padding, rounded
/// corners, and a shadow. Live preview re-renders from a downscaled copy; export is full-res.
@MainActor
final class BeautifyWindowController: NSWindowController, NSWindowDelegate {

    private let fullBase: CGImage
    private let previewBase: CGImage
    private let mode: CaptureMode
    private var style = BeautifyStyle.makeDefault()
    private let preview = BeautifyView()
    var onClose: (() -> Void)?

    init(image: CapturedImage, mode: CaptureMode) {
        self.fullBase = image.cgImage
        self.previewBase = Self.downscale(image.cgImage, maxSide: 1100) ?? image.cgImage
        self.mode = mode

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Beautify Screenshot"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        renderPreview()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        preview.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preview)

        let presetPopup = NSPopUpButton()
        for preset in BackgroundPreset.all { presetPopup.addItem(withTitle: preset.name) }
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))

        let colorWell = NSColorWell()
        colorWell.color = .white
        colorWell.target = self
        colorWell.action = #selector(solidColorChanged(_:))
        colorWell.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let framePopup = NSPopUpButton()
        for frame in WindowFrame.allCases { framePopup.addItem(withTitle: frame.presentableName) }
        framePopup.selectItem(at: style.windowFrame.rawValue)
        framePopup.target = self
        framePopup.action = #selector(frameChanged(_:))

        let padding = makeSlider(min: 0, max: 0.25, value: style.paddingFraction, action: #selector(paddingChanged(_:)))
        let corner = makeSlider(min: 0, max: 0.12, value: style.cornerFraction, action: #selector(cornerChanged(_:)))
        let shadowSwitch = NSSwitch()
        shadowSwitch.state = style.shadow ? .on : .off
        shadowSwitch.target = self
        shadowSwitch.action = #selector(shadowToggled(_:))

        let imageButton = makeButton("Image…", "photo", #selector(chooseBackgroundImage))

        let aspectPopup = NSPopUpButton()
        aspectPopup.addItems(withTitles: ["Original", "Square", "4:3", "16:9"])
        aspectPopup.target = self
        aspectPopup.action = #selector(aspectChanged(_:))

        let left = NSStackView(views: [
            label("Background"), presetPopup, colorWell, imageButton,
            label("Aspect"), aspectPopup,
            label("Frame"), framePopup,
            label("Padding"), padding,
            label("Corner"), corner,
            label("Shadow"), shadowSwitch,
        ])
        left.spacing = 8
        left.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(left)

        let copy = makeButton("Copy", "doc.on.doc", #selector(copyTapped))
        let save = makeButton("Save", "arrow.down.circle", #selector(saveTapped))
        let done = makeButton("Done", nil, #selector(doneTapped))
        done.keyEquivalent = "\r"
        let right = NSStackView(views: [copy, save, done])
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(right)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48),
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            preview.topAnchor.constraint(equalTo: bar.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func makeSlider(min: Double, max: Double, value: CGFloat, action: Selector) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: min, maxValue: max, target: self, action: action)
        slider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return slider
    }

    private func makeButton(_ title: String, _ symbol: String?, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        button.imagePosition = symbol == nil ? .noImage : .imageLeading
        return button
    }

    // MARK: Rendering

    private func renderPreview() {
        preview.image = BeautifyRenderer.render(base: previewBase, style: style)
    }

    private static func downscale(_ image: CGImage, maxSide: CGFloat) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = Swift.min(1, maxSide / Swift.max(w, h))
        guard scale < 1 else { return image }
        let outW = Int(w * scale), outH = Int(h * scale)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage()
    }

    // MARK: Actions

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if BackgroundPreset.all.indices.contains(index) {
            style.background = BackgroundPreset.all[index].fill
            renderPreview()
        }
    }

    @objc private func solidColorChanged(_ sender: NSColorWell) {
        style.background = .solid(sender.color)
        renderPreview()
    }

    @objc private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let nsImage = NSImage(contentsOf: url) else { return }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        style.background = .image(cg)
        renderPreview()
    }

    @objc private func aspectChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1: style.targetAspect = 1
        case 2: style.targetAspect = 4.0 / 3.0
        case 3: style.targetAspect = 16.0 / 9.0
        default: style.targetAspect = nil
        }
        renderPreview()
    }

    @objc private func frameChanged(_ sender: NSPopUpButton) {
        style.windowFrame = WindowFrame(rawValue: sender.indexOfSelectedItem) ?? .none
        renderPreview()
    }

    @objc private func paddingChanged(_ sender: NSSlider) { style.paddingFraction = CGFloat(sender.doubleValue); renderPreview() }
    @objc private func cornerChanged(_ sender: NSSlider) { style.cornerFraction = CGFloat(sender.doubleValue); renderPreview() }
    @objc private func shadowToggled(_ sender: NSSwitch) { style.shadow = (sender.state == .on); renderPreview() }

    @objc private func copyTapped() {
        if let cg = BeautifyRenderer.render(base: fullBase, style: style) { PasteboardWriter.copy(cg) }
    }

    @objc private func saveTapped() {
        guard let cg = BeautifyRenderer.render(base: fullBase, style: style) else { return }
        let captured = CapturedImage(cgImage: cg, scale: 1, displayID: nil)
        let mode = self.mode
        Task.detached { _ = try? FileSaver.save(captured.cgImage, mode: mode) }
    }

    @objc private func doneTapped() { close() }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
