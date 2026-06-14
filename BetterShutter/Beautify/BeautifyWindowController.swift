import AppKit
import UniformTypeIdentifiers

/// Beautify editor: drop a screenshot onto a gradient/solid background with padding, rounded
/// corners, and a shadow. Live preview re-renders from a downscaled copy; export is full-res.
@MainActor
final class BeautifyWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    private let fullBase: CGImage
    private let previewBase: CGImage
    private let mode: CaptureMode
    private var style = BeautifyStyle.makeDefault()
    private let preview = BeautifyView()
    var onClose: (() -> Void)?

    // Retained so applying a preset can sync them back to the new style.
    private var paddingSlider: NSSlider?
    private var cornerSlider: NSSlider?
    private var shadowSwitch: NSSwitch?
    private var framePopup: NSPopUpButton?
    private var perspectivePopup: NSPopUpButton?
    private var aspectPopup: NSPopUpButton?
    private let presetButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]

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
        window.toolbarStyle = .unified
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
        preview.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

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

        let perspectivePopup = NSPopUpButton()
        for option in BeautifyPerspective.allCases { perspectivePopup.addItem(withTitle: option.presentableName) }
        perspectivePopup.selectItem(at: style.perspective.rawValue)
        perspectivePopup.target = self
        perspectivePopup.action = #selector(perspectiveChanged(_:))

        let padding = makeSlider(min: 0, max: 0.25, value: style.paddingFraction, action: #selector(paddingChanged(_:)))
        let corner = makeSlider(min: 0, max: 0.12, value: style.cornerFraction, action: #selector(cornerChanged(_:)))
        let shadowToggle = NSSwitch()
        shadowToggle.state = style.shadow ? .on : .off
        shadowToggle.target = self
        shadowToggle.action = #selector(shadowToggled(_:))

        let imageButton = makeButton("Image…", "photo", #selector(chooseBackgroundImage))

        let aspectPopup = NSPopUpButton()
        aspectPopup.addItems(withTitles: ["Original", "Square", "4:3", "16:9"])
        aspectPopup.target = self
        aspectPopup.action = #selector(aspectChanged(_:))

        configurePresetButton()
        self.paddingSlider = padding
        self.cornerSlider = corner
        self.shadowSwitch = shadowToggle
        self.framePopup = framePopup
        self.perspectivePopup = perspectivePopup
        self.aspectPopup = aspectPopup

        let copy = makeButton("Copy", "doc.on.doc", #selector(copyTapped))
        let save = makeButton("Save", "arrow.down.circle", #selector(saveTapped))
        let done = makeButton("Done", nil, #selector(doneTapped))
        done.keyEquivalent = "\r"   // NSToolbarItem has no keyEquivalent — keep Done a real default button

        register(.beautifyBackground, group([label("Background"), presetPopup, colorWell, imageButton]), label: "Background")
        register(.beautifyAspect, group([label("Aspect"), aspectPopup]), label: "Aspect")
        register(.beautifyFrame, group([label("Frame"), framePopup]), label: "Frame")
        register(.beautifyPerspective, group([label("3D"), perspectivePopup]), label: "3D")
        register(.beautifyPadding, group([label("Padding"), padding]), label: "Padding")
        register(.beautifyCorner, group([label("Corner"), corner]), label: "Corner")
        register(.beautifyShadow, group([label("Shadow"), shadowToggle]), label: "Shadow")
        register(.beautifyPresets, presetButton, label: "Presets")
        register(.beautifyCopy, copy, label: "Copy")
        register(.beautifySave, save, label: "Save")
        register(.beautifyDone, done, label: "Done")

        let toolbar = NSToolbar(identifier: "BeautifyToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    /// Packs a label and its control(s) into one toolbar-item view, preserving the inline pairing the
    /// old control strip had.
    private func group(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        return stack
    }

    /// Wraps a view as a toolbar item; the contained controls keep their own target/action.
    private func register(_ id: NSToolbarItem.Identifier, _ view: NSView, label: String) {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = view
        item.label = label
        item.toolTip = view.toolTip ?? label
        toolbarItems[id] = item
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
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .rounded
        }
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

    @objc private func perspectiveChanged(_ sender: NSPopUpButton) {
        style.perspective = BeautifyPerspective(rawValue: sender.indexOfSelectedItem) ?? .none
        renderPreview()
    }

    @objc private func frameChanged(_ sender: NSPopUpButton) {
        style.windowFrame = WindowFrame(rawValue: sender.indexOfSelectedItem) ?? .none
        renderPreview()
    }

    @objc private func paddingChanged(_ sender: NSSlider) { style.paddingFraction = CGFloat(sender.doubleValue); renderPreview() }
    @objc private func cornerChanged(_ sender: NSSlider) { style.cornerFraction = CGFloat(sender.doubleValue); renderPreview() }
    @objc private func shadowToggled(_ sender: NSSwitch) { style.shadow = (sender.state == .on); renderPreview() }

    // MARK: Presets

    private func configurePresetButton() {
        presetButton.bezelStyle = .texturedRounded
        presetButton.imagePosition = .imageOnly
        presetButton.toolTip = "Beautify Style Presets"
        rebuildPresetMenu()
    }

    private func rebuildPresetMenu() {
        let menu = NSMenu()
        let face = NSMenuItem()
        face.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Presets")
        menu.addItem(face)

        let save = NSMenuItem(title: "Save Current Style…", action: #selector(savePresetTapped), keyEquivalent: "")
        save.target = self
        menu.addItem(save)

        let presets = Preferences.beautifyPresets
        if !presets.isEmpty {
            menu.addItem(.separator())
            for preset in presets {
                let item = NSMenuItem(title: preset.name, action: #selector(applyPresetTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.name
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let deleteSub = NSMenu()
            for preset in presets {
                let item = NSMenuItem(title: preset.name, action: #selector(deletePresetTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.name
                deleteSub.addItem(item)
            }
            let deleteItem = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
            deleteItem.submenu = deleteSub
            menu.addItem(deleteItem)

            menu.addItem(.separator())
            let autoSub = NSMenu()
            let off = NSMenuItem(title: "Off", action: #selector(setAutoApply(_:)), keyEquivalent: "")
            off.target = self; off.representedObject = ""
            off.state = Preferences.autoBeautifyPresetName == nil ? .on : .off
            autoSub.addItem(off)
            autoSub.addItem(.separator())
            for preset in presets {
                let item = NSMenuItem(title: preset.name, action: #selector(setAutoApply(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = preset.name
                item.state = Preferences.autoBeautifyPresetName == preset.name ? .on : .off
                autoSub.addItem(item)
            }
            let autoItem = NSMenuItem(title: "Auto-Apply to Captures", action: nil, keyEquivalent: "")
            autoItem.submenu = autoSub
            menu.addItem(autoItem)
        }
        presetButton.menu = menu
    }

    @objc private func setAutoApply(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String
        Preferences.autoBeautifyPresetName = (name?.isEmpty ?? true) ? nil : name
        rebuildPresetMenu()
    }

    @objc private func savePresetTapped() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Style Preset"
        alert.informativeText = "Name this beautify style for one-click reuse."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            Preferences.addBeautifyPreset(BeautifyPreset(name: name, style: self.style))
            self.rebuildPresetMenu()
        }
    }

    @objc private func applyPresetTapped(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let preset = Preferences.beautifyPresets.first(where: { $0.name == name }) else { return }
        style = preset.applied(to: style)
        syncControls()
        renderPreview()
    }

    @objc private func deletePresetTapped(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Preferences.removeBeautifyPreset(named: name)
        rebuildPresetMenu()
    }

    private func syncControls() {
        paddingSlider?.doubleValue = Double(style.paddingFraction)
        cornerSlider?.doubleValue = Double(style.cornerFraction)
        shadowSwitch?.state = style.shadow ? .on : .off
        framePopup?.selectItem(at: style.windowFrame.rawValue)
        perspectivePopup?.selectItem(at: style.perspective.rawValue)
        aspectPopup?.selectItem(at: aspectIndex(for: style.targetAspect))
    }

    private func aspectIndex(for aspect: CGFloat?) -> Int {
        guard let a = aspect else { return 0 }
        if abs(a - 1) < 0.01 { return 1 }
        if abs(a - 4.0 / 3.0) < 0.01 { return 2 }
        if abs(a - 16.0 / 9.0) < 0.01 { return 3 }
        return 0
    }

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

    // MARK: NSToolbarDelegate

    private var orderedToolbarItems: [NSToolbarItem.Identifier] {
        [.beautifyBackground, .beautifyAspect, .beautifyFrame, .beautifyPerspective, .beautifyPadding,
         .beautifyCorner, .beautifyShadow, .beautifyPresets, .flexibleSpace,
         .beautifyCopy, .beautifySave, .beautifyDone]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { orderedToolbarItems }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { orderedToolbarItems }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        toolbarItems[itemIdentifier]
    }
}

private extension NSToolbarItem.Identifier {
    static let beautifyBackground = NSToolbarItem.Identifier("beautify.background")
    static let beautifyAspect = NSToolbarItem.Identifier("beautify.aspect")
    static let beautifyFrame = NSToolbarItem.Identifier("beautify.frame")
    static let beautifyPerspective = NSToolbarItem.Identifier("beautify.perspective")
    static let beautifyPadding = NSToolbarItem.Identifier("beautify.padding")
    static let beautifyCorner = NSToolbarItem.Identifier("beautify.corner")
    static let beautifyShadow = NSToolbarItem.Identifier("beautify.shadow")
    static let beautifyPresets = NSToolbarItem.Identifier("beautify.presets")
    static let beautifyCopy = NSToolbarItem.Identifier("beautify.copy")
    static let beautifySave = NSToolbarItem.Identifier("beautify.save")
    static let beautifyDone = NSToolbarItem.Identifier("beautify.done")
}
