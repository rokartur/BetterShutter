import AppKit

/// Hosts the annotation editor: a tool/style/action bar above the canvas. Copy and Save flatten
/// the annotations onto the capture at full resolution.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    private let canvas: EditorCanvasView
    private let mode: CaptureMode
    var onClose: (() -> Void)?

    init(image: CapturedImage, mode: CaptureMode) {
        self.canvas = EditorCanvasView(image: image)
        self.mode = mode

        // Floor wide enough for the full tool segmented control (13 tools) + color/stroke + the
        // Copy/Save/Done action buttons without the left and right stacks overlapping.
        let minContentWidth: CGFloat = 860
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
        let colorWell = NSColorWell()
        colorWell.color = canvas.style.color
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let widthSlider = NSSlider(value: Double(canvas.style.strokeWidth), minValue: 1, maxValue: 40,
                                   target: self, action: #selector(widthChanged(_:)))
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let leftStack = NSStackView(views: [tools, colorWell, widthSlider])
        leftStack.spacing = 10
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(leftStack)

        let copy = makeActionButton(title: "Copy", symbol: "doc.on.doc", action: #selector(copyTapped))
        let save = makeActionButton(title: "Save", symbol: "arrow.down.circle", action: #selector(saveTapped))
        let done = makeActionButton(title: "Done", symbol: nil, action: #selector(doneTapped))
        done.keyEquivalent = "\r"
        let rightStack = NSStackView(views: [copy, save, done])
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
            seg.setToolTip(kind.label, forSegment: index)
            seg.setWidth(30, forSegment: index)
        }
        seg.selectedSegment = ToolKind.allCases.firstIndex(of: canvas.tool) ?? 1
        seg.target = self
        seg.action = #selector(toolChanged(_:))
        seg.translatesAutoresizingMaskIntoConstraints = false
        return seg
    }

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

    @objc private func colorChanged(_ sender: NSColorWell) { canvas.applyColor(sender.color) }
    @objc private func widthChanged(_ sender: NSSlider) { canvas.applyStrokeWidth(CGFloat(sender.doubleValue)) }

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
