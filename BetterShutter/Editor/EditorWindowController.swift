import AppKit
import UniformTypeIdentifiers

/// Hosts the annotation editor: a tool/style/action bar above the canvas. Copy and Save flatten
/// the annotations onto the capture at full resolution.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    private let canvas: EditorCanvasView
    private let mode: CaptureMode
    private var toolControl: NSSegmentedControl?
    private var colorWell: NSColorWell?
    private let swatches = NSPopUpButton(frame: .zero, pullsDown: true)
    var onClose: (() -> Void)?

    init(image: CapturedImage, mode: CaptureMode, elements: [AnnotationElement] = []) {
        self.canvas = EditorCanvasView(image: image, elements: elements)
        self.mode = mode

        // Floor wide enough for the full tool segmented control (13 tools) + color/stroke + the
        // Project/Share/Copy/Save/Done action buttons without the left and right stacks overlapping.
        let minContentWidth: CGFloat = 1000
        let canvasSize = EditorCanvasView.fittedSize(for: image.pixelSize)
        let contentRect = NSRect(x: 0, y: 0,
                                 width: max(canvasSize.width, minContentWidth),
                                 height: canvasSize.height + 48)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Edit Screenshot"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: minContentWidth, height: 240)
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

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)

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
        widthSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let leftStack = NSStackView(views: [tools, colorWell, swatches, widthSlider, makeTransformControl()])
        leftStack.spacing = 10
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(leftStack)

        let project = makeActionButton(title: "", symbol: "doc.badge.gearshape", action: #selector(saveProjectTapped))
        project.toolTip = "Save Re-editable Project (.bsproj)"
        let share = makeActionButton(title: "", symbol: "square.and.arrow.up", action: #selector(shareTapped(_:)))
        share.toolTip = "Share"
        let copy = makeActionButton(title: "Copy", symbol: "doc.on.doc", action: #selector(copyTapped))
        let save = makeActionButton(title: "Save", symbol: "arrow.down.circle", action: #selector(saveTapped))
        let done = makeActionButton(title: "Done", symbol: nil, action: #selector(doneTapped))
        done.keyEquivalent = "\r"
        let rightStack = NSStackView(views: [project, share, copy, save, done])
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(rightStack)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48),

            leftStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            leftStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rightStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            rightStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 16),

            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
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
        NSColor.black.withAlphaComponent(0.2).setStroke(); path.lineWidth = 0.5; path.stroke()
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
        button.bezelStyle = .rounded
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

    @objc private func invertPicked() { canvas.invertColors() }
    @objc private func autoRedactPicked() { canvas.autoRedactPII() }

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
}
