import AppKit
import UniformTypeIdentifiers

/// Hosts the annotation editor: a tool/style/action bar above the canvas. Copy and Save flatten
/// the annotations onto the capture at full resolution.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    private let canvas: EditorCanvasView
    private let mode: CaptureMode
    private var toolControl: NSSegmentedControl?
    private var colorWell: NSColorWell?
    private let swatches = NSPopUpButton(frame: .zero, pullsDown: true)
    private var widthSlider: NSSlider?
    private var strengthSlider: NSSlider?
    private var transformControl: NSPopUpButton?
    private var zoomControl: NSSegmentedControl?
    private var adjustPopover: NSPopover?
    private var adjustSliders: [String: NSSlider] = [:]
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    var onClose: (() -> Void)?

    init(image: CapturedImage, mode: CaptureMode, elements: [AnnotationElement] = []) {
        self.canvas = EditorCanvasView(image: image, elements: elements)
        self.mode = mode

        // Floor wide enough for the bottom bar's style controls plus the Project/Share/Copy/Save/Done
        // actions side by side, so nothing spills into an overflow menu.
        let minContentWidth: CGFloat = 1240
        let canvasSize = EditorCanvasView.fittedSize(for: image.pixelSize)
        let contentRect = NSRect(x: 0, y: 0,
                                 width: max(canvasSize.width, minContentWidth),
                                 height: canvasSize.height)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Edit Screenshot"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: minContentWidth, height: 320)
        window.toolbarStyle = .unified
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Split the chrome so nothing has to overflow: the tool picker rides the top toolbar, the
        // style controls (color / saved colors / stroke / transform) and file actions
        // (project / share / copy / save / done) ride a bottom glass bar, and the canvas sits between
        // them. Everything stays visible at once.
        let tools = makeToolControl()
        toolControl = tools
        canvas.onToolPicked = { [weak self] kind in
            self?.toolControl?.selectedSegment = ToolKind.allCases.firstIndex(of: kind) ?? 0
        }
        let colorWell = NSColorWell()
        colorWell.color = canvas.style.color
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        self.colorWell = colorWell
        canvas.onColorPicked = { [weak self] color in
            self?.colorWell?.color = color
            if let hex = color.hexString { Preferences.addRecentColor(hex); self?.rebuildSwatches() }
        }
        canvas.onPrint = { [weak self] in
            if let cg = self?.canvas.flattened() { Printing.printImage(cg) }
        }
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 40).isActive = true

        configureSwatches()

        let widthSlider = NSSlider(value: Double(canvas.style.strokeWidth), minValue: 1, maxValue: 40,
                                   target: self, action: #selector(widthChanged(_:)))
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        self.widthSlider = widthSlider

        // Pixelate/blur redaction strength — size-independent (see AnnotationStyle.redactionStrength).
        let strengthSlider = NSSlider(value: Double(canvas.style.redactionStrength), minValue: 0, maxValue: 1,
                                      target: self, action: #selector(strengthChanged(_:)))
        strengthSlider.translatesAutoresizingMaskIntoConstraints = false
        strengthSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        strengthSlider.toolTip = "Pixelate / Blur strength"
        self.strengthSlider = strengthSlider

        let transform = makeTransformControl()
        self.transformControl = transform

        let zoom = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom out") ?? NSImage(),
                NSImage(systemSymbolName: "arrow.up.left.and.down.right.magnifyingglass", accessibilityDescription: "Fit") ?? NSImage(),
                NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom in") ?? NSImage(),
            ],
            trackingMode: .momentary, target: self, action: #selector(zoomTapped(_:)))
        zoom.toolTip = "Zoom (⌘− / ⌘0 / ⌘+, or pinch)"
        self.zoomControl = zoom

        let adjustButton = NSButton(
            image: NSImage(systemSymbolName: "slider.horizontal.below.square.filled.and.square", accessibilityDescription: "Adjust") ?? NSImage(),
            target: self, action: #selector(adjustTapped(_:)))
        adjustButton.bezelStyle = .texturedRounded
        adjustButton.imagePosition = .imageOnly
        adjustButton.toolTip = "Image Adjustments (brightness / contrast / saturation / sharpness)"

        // Action buttons (project / share / copy / save / done) ride the bottom bar, right side.
        let project = makeActionButton(title: "", symbol: "doc.badge.gearshape", action: #selector(saveProjectTapped))
        project.toolTip = "Save Re-editable Project (.bsproj)"
        let share = makeActionButton(title: "", symbol: "square.and.arrow.up", action: #selector(shareTapped(_:)))
        share.toolTip = "Share"
        let copy = makeActionButton(title: "Copy", symbol: "doc.on.doc", action: #selector(copyTapped))
        let save = makeActionButton(title: "Save", symbol: "arrow.down.circle", action: #selector(saveTapped))
        let done = makeActionButton(title: "Done", symbol: nil, action: #selector(doneTapped))
        done.keyEquivalent = "\r"   // default button — fires on Return

        // Bottom glass bar: style controls on the left, file actions on the right.
        let styleStack = NSStackView(views: [
            label("Color"), colorWell, swatches,
            label("Stroke"), widthSlider,
            label("Strength"), strengthSlider,
            label("Transform"), transform,
            label("Adjust"), adjustButton,
            label("Zoom"), zoom,
        ])
        styleStack.orientation = .horizontal
        styleStack.alignment = .centerY
        styleStack.spacing = 8
        styleStack.translatesAutoresizingMaskIntoConstraints = false

        let actionStack = NSStackView(views: [project, share, copy, save, done])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        let styleBar = GlassPanelView(cornerRadius: GlassTokens.Radius.bar)
        styleBar.translatesAutoresizingMaskIntoConstraints = false
        styleBar.contentView.addSubview(styleStack)
        styleBar.contentView.addSubview(actionStack)
        content.addSubview(styleBar)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: styleBar.topAnchor, constant: -10),

            styleBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            styleBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            styleBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            // Fixed height (not tied to the stack) avoids a layout-recursion loop with the glass
            // view re-laying out its contentView.
            styleBar.heightAnchor.constraint(equalToConstant: 44),

            styleStack.leadingAnchor.constraint(equalTo: styleBar.contentView.leadingAnchor, constant: 14),
            styleStack.centerYAnchor.constraint(equalTo: styleBar.contentView.centerYAnchor),

            actionStack.trailingAnchor.constraint(equalTo: styleBar.contentView.trailingAnchor, constant: -14),
            actionStack.centerYAnchor.constraint(equalTo: styleBar.contentView.centerYAnchor),
            actionStack.leadingAnchor.constraint(greaterThanOrEqualTo: styleStack.trailingAnchor, constant: 16),
        ])

        register(.editorTools, tools, label: "Tools")

        let toolbar = NSToolbar(identifier: "EditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// Wraps an existing control as a toolbar item, carrying its tooltip. The control keeps its own
    /// target/action, so all wiring is preserved across the NSToolbar migration.
    private func register(_ id: NSToolbarItem.Identifier, _ view: NSView, label: String) {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = view
        item.label = label
        item.toolTip = view.toolTip ?? label
        toolbarItems[id] = item
    }

    private func makeToolControl() -> NSSegmentedControl {
        let seg = NSSegmentedControl()
        seg.segmentCount = ToolKind.allCases.count
        seg.trackingMode = .selectOne
        for (index, kind) in ToolKind.allCases.enumerated() {
            seg.setImage(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.label), forSegment: index)
            seg.setToolTip("\(kind.label) (\(kind.effectiveShortcutKey.uppercased()))", forSegment: index)
            seg.setWidth(30, forSegment: index)
        }
        seg.selectedSegment = ToolKind.allCases.firstIndex(of: canvas.tool) ?? 1
        seg.target = self
        seg.action = #selector(toolChanged(_:))
        seg.translatesAutoresizingMaskIntoConstraints = false
        return seg
    }

    private func configureSwatches() {
        swatches.translatesAutoresizingMaskIntoConstraints = false
        swatches.bezelStyle = .texturedRounded
        swatches.imagePosition = .imageOnly
        swatches.toolTip = "Saved Colors"
        rebuildSwatches()
    }

    private func rebuildSwatches() {
        let menu = NSMenu()
        let face = NSMenuItem()
        face.image = NSImage(systemSymbolName: "swatchpalette", accessibilityDescription: "Saved Colors")
        menu.addItem(face)
        let colors = Preferences.recentColors
        if colors.isEmpty {
            let empty = NSMenuItem(title: "No saved colors yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for hex in colors {
                guard let color = NSColor(hexString: hex) else { continue }
                let item = NSMenuItem(title: hex, action: #selector(swatchPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = hex
                item.image = Self.swatchImage(color)
                menu.addItem(item)
            }
        }
        swatches.menu = menu
    }

    private static func swatchImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3)
        color.setFill(); path.fill()
        GlassTokens.Fixed.swatchStroke.setStroke(); path.lineWidth = 0.5; path.stroke()
        image.unlockFocus()
        return image
    }

    @objc private func swatchPicked(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String, let color = NSColor(hexString: hex) else { return }
        canvas.applyColor(color)
        colorWell?.color = color
        Preferences.addRecentColor(hex)
        rebuildSwatches()
    }

    private func makeTransformControl() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.bezelStyle = .texturedRounded
        popup.imagePosition = .imageOnly
        // First item is the (hidden) pull-down face.
        let face = NSMenuItem()
        face.image = NSImage(systemSymbolName: "crop.rotate", accessibilityDescription: "Transform")
        popup.menu?.addItem(face)
        for kind in ImageTransform.allCases {
            let item = NSMenuItem(title: kind.actionName, action: #selector(transformPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind
            popup.menu?.addItem(item)
        }
        popup.menu?.addItem(.separator())
        let invert = NSMenuItem(title: "Invert Colors", action: #selector(invertPicked), keyEquivalent: "")
        invert.target = self
        popup.menu?.addItem(invert)
        let redact = NSMenuItem(title: "Auto-Redact PII", action: #selector(autoRedactPicked), keyEquivalent: "")
        redact.target = self
        popup.menu?.addItem(redact)
        let addImage = NSMenuItem(title: "Add Image…", action: #selector(addImagePicked), keyEquivalent: "")
        addImage.target = self
        popup.menu?.addItem(addImage)
        let watermark = NSMenuItem(title: "Add Watermark…", action: #selector(addWatermarkPicked), keyEquivalent: "")
        watermark.target = self
        popup.menu?.addItem(watermark)
        popup.menu?.addItem(.separator())
        for (title, filter) in Self.filters {
            let item = NSMenuItem(title: title, action: #selector(filterPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = filter
            popup.menu?.addItem(item)
        }
        popup.toolTip = "Rotate / Flip / Filters"
        return popup
    }

    private static let filters: [(String, String)] = [
        ("Noir", "CIPhotoEffectNoir"), ("Mono", "CIPhotoEffectMono"), ("Sepia", "CISepiaTone"),
        ("Chrome", "CIPhotoEffectChrome"), ("Fade", "CIPhotoEffectFade"),
        ("Instant", "CIPhotoEffectInstant"), ("Vivid", "CIPhotoEffectTransfer"),
    ]

    private func makeActionButton(title: String, symbol: String?, action: Selector) -> NSButton {
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

    // MARK: Actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        canvas.tool = ToolKind.allCases[sender.selectedSegment]
    }

    @objc private func transformPicked(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? ImageTransform else { return }
        canvas.applyImageTransform(kind)
    }

    // MARK: Image adjustments

    @objc private func adjustTapped(_ sender: NSButton) {
        let popover = adjustPopover ?? makeAdjustPopover()
        adjustPopover = popover
        if popover.isShown { popover.close() }
        else { popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY) }
    }

    private func makeAdjustPopover() -> NSPopover {
        let a = canvas.currentAdjustments
        adjustSliders = [:]
        func row(_ key: String, _ title: String, min: Double, max: Double, value: Double) -> NSStackView {
            let slider = NSSlider(value: value, minValue: min, maxValue: max,
                                  target: self, action: #selector(adjustSliderChanged))
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            adjustSliders[key] = slider
            let caption = NSTextField(labelWithString: title)
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            caption.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let stack = NSStackView(views: [caption, slider])
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetAdjustTapped))
        reset.bezelStyle = .rounded
        let content = NSStackView(views: [
            row("brightness", "Brightness", min: -0.5, max: 0.5, value: a.brightness),
            row("contrast", "Contrast", min: 0.5, max: 1.5, value: a.contrast),
            row("saturation", "Saturation", min: 0, max: 2, value: a.saturation),
            row("sharpness", "Sharpness", min: 0, max: 1, value: a.sharpness),
            reset,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false

        let vc = NSViewController()
        vc.view = content

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 190)
        return popover
    }

    @objc private func adjustSliderChanged() {
        var a = ImageAdjustments()
        a.brightness = adjustSliders["brightness"]?.doubleValue ?? 0
        a.contrast = adjustSliders["contrast"]?.doubleValue ?? 1
        a.saturation = adjustSliders["saturation"]?.doubleValue ?? 1
        a.sharpness = adjustSliders["sharpness"]?.doubleValue ?? 0
        // Coalesce a whole slider drag into one undo step: commit only on mouse-up.
        canvas.setAdjustments(a, commit: NSApp.currentEvent?.type == .leftMouseUp)
    }

    @objc private func resetAdjustTapped() {
        canvas.resetAdjustments()
        adjustSliders["brightness"]?.doubleValue = 0
        adjustSliders["contrast"]?.doubleValue = 1
        adjustSliders["saturation"]?.doubleValue = 1
        adjustSliders["sharpness"]?.doubleValue = 0
    }

    @objc private func zoomTapped(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: canvas.zoomOut()
        case 1: canvas.zoomToFit()
        default: canvas.zoomIn()
        }
    }

    @objc private func invertPicked() { canvas.invertColors() }
    @objc private func autoRedactPicked() { canvas.autoRedactPII() }
    @objc private func addWatermarkPicked() { canvas.addWatermark() }

    @objc private func addImagePicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let nsImage = NSImage(contentsOf: url) else { return }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        canvas.addComposedImage(cg)
    }

    @objc private func filterPicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        canvas.applyFilter(named: name)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.applyColor(sender.color)
        if let hex = sender.color.hexString { Preferences.addRecentColor(hex); rebuildSwatches() }
    }
    @objc private func widthChanged(_ sender: NSSlider) { canvas.applyStrokeWidth(CGFloat(sender.doubleValue)) }
    @objc private func strengthChanged(_ sender: NSSlider) { canvas.applyRedactionStrength(CGFloat(sender.doubleValue)) }

    @objc private func saveProjectTapped() {
        guard let window,
              let project = AnnotationProjectIO.make(base: canvas.baseCGImage, elements: canvas.projectElements())
        else { return }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: AnnotationProjectIO.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "Project.\(AnnotationProjectIO.fileExtension)"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? AnnotationProjectIO.write(project, to: url)
        }
    }

    @objc private func shareTapped(_ sender: NSButton) {
        guard let cg = canvas.flattened() else { return }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let picker = NSSharingServicePicker(items: [image])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func copyTapped() {
        if let cg = canvas.flattened() { PasteboardWriter.copy(cg) }
    }

    @objc private func saveTapped() {
        guard let cg = canvas.flattened() else { return }
        let captured = CapturedImage(cgImage: cg, scale: 1, displayID: nil)
        let mode = self.mode
        Task.detached { _ = try? FileSaver.save(captured.cgImage, mode: mode) }
    }

    @objc private func doneTapped() { close() }

    func windowWillClose(_ notification: Notification) { onClose?() }

    // MARK: NSToolbarDelegate

    private var orderedToolbarItems: [NSToolbarItem.Identifier] {
        [.editorTools]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { orderedToolbarItems }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { orderedToolbarItems }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        toolbarItems[itemIdentifier]
    }
}

private extension NSToolbarItem.Identifier {
    static let editorTools = NSToolbarItem.Identifier("editor.tools")
}
