import AppKit

/// Builds one capture overlay per screen from the frozen bitmaps, runs the selection, and hands
/// back a cropped region image or a chosen window id. Owns the system-cursor hide/unhide balance.
@MainActor
final class OverlayController {

    private struct Pane {
        let window: OverlayWindow
        let view: OverlayView
        let screenFrame: CGRect
        let image: CapturedImage
    }

    private var panes: [Pane] = []
    private var cursorHidden = false
    private var screenObserver: NSObjectProtocol?

    private var onRegion: ((CapturedImage, CGRect, CGDirectDisplayID, OverlayAction) -> Void)?
    private var onWindow: ((CGWindowID) -> Void)?
    private var onCancel: (() -> Void)?

    var isPresenting: Bool { !panes.isEmpty }

    // MARK: Present

    func present(
        frozen: [CapturedImage],
        windows: [WindowInfo],
        magnifierEnabled: Bool,
        toolbarActions: [OverlayAction] = [],
        instantCapture: Bool = false,
        onRegion: @escaping (CapturedImage, CGRect, CGDirectDisplayID, OverlayAction) -> Void,
        onWindow: @escaping (CGWindowID) -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss() // never stack overlays

        self.onRegion = onRegion
        self.onWindow = onWindow
        self.onCancel = onCancel

        let byDisplay = Dictionary(
            frozen.compactMap { img in img.displayID.map { ($0, img) } },
            uniquingKeysWith: { a, _ in a }
        )
        let primaryHeight = Self.primaryHeight()
        let mouse = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            guard let displayID = screen.displayID, let image = byDisplay[displayID] else { continue }
            let frame = screen.frame

            let window = OverlayWindow(screenFrame: frame)
            let container = window.contentView ?? NSView(frame: NSRect(origin: .zero, size: frame.size))
            container.wantsLayer = true

            let background = NSImageView(frame: container.bounds)
            background.image = NSImage(cgImage: image.cgImage, size: frame.size)
            background.imageScaling = .scaleAxesIndependently
            background.autoresizingMask = [.width, .height]
            container.addSubview(background)

            let view = OverlayView(
                frozenImage: image.cgImage,
                pixelSize: image.pixelSize,
                frame: container.bounds
            )
            view.autoresizingMask = [.width, .height]
            view.magnifierEnabled = magnifierEnabled
            view.toolbarActions = toolbarActions
            view.instantCapture = instantCapture
            view.setCursorHidden = { [weak self] hidden in hidden ? self?.hideCursor() : self?.showCursor() }
            view.windowHits = WindowHighlighter.viewRects(
                windows: windows, primaryHeight: primaryHeight, screenGlobalFrame: frame
            )
            container.addSubview(view)

            let pane = Pane(window: window, view: view, screenFrame: frame, image: image)
            view.onRegionSelected = { [weak self] rect, action in self?.handleRegion(rect, in: pane, action: action) }
            view.onWindowSelected = { [weak self] id in self?.handleWindow(id) }
            view.onCancel = { [weak self] in self?.handleCancel() }

            window.makeKeyAndOrderFront(nil)
            panes.append(pane)

            // Make the overlay under the cursor key so Esc/Enter land there.
            if frame.contains(mouse) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
            }
        }

        guard !panes.isEmpty else { onCancel(); return }

        // Fallback: ensure some pane is key/first-responder.
        if let key = panes.first(where: { $0.window.isKeyWindow }) ?? panes.first {
            key.window.makeKeyAndOrderFront(nil)
            key.window.makeFirstResponder(key.view)
        }

        NSApp.activate(ignoringOtherApps: true)
        hideCursor()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // A display was added/removed mid-capture — cancel rather than strand an overlay.
            MainActor.assumeIsolated { self?.handleCancel() }
        }
    }

    // MARK: Outcomes

    private func handleRegion(_ viewRect: CGRect, in pane: Pane, action: OverlayAction) {
        let globalRect = CGRect(
            x: viewRect.minX + pane.screenFrame.minX,
            y: viewRect.minY + pane.screenFrame.minY,
            width: viewRect.width,
            height: viewRect.height
        )
        let cropPx = CoordinateConverter.pixelCropRect(
            globalRect: globalRect,
            displayFrame: pane.screenFrame,
            pixelSize: pane.image.pixelSize
        )
        let onRegion = self.onRegion
        let onCancel = self.onCancel
        let displayID = pane.image.displayID ?? CGMainDisplayID()
        dismiss()
        guard cropPx.width >= 1, cropPx.height >= 1,
              let cropped = pane.image.cgImage.cropping(to: cropPx) else {
            // A degenerate selection must still release the caller's capture lock.
            onCancel?()
            return
        }
        onRegion?(CapturedImage(cgImage: cropped, scale: pane.image.scale, displayID: pane.image.displayID),
                  globalRect, displayID, action)
    }

    private func handleWindow(_ id: CGWindowID) {
        let onWindow = self.onWindow
        dismiss()
        onWindow?(id)
    }

    private func handleCancel() {
        let onCancel = self.onCancel
        dismiss()
        onCancel?()
    }

    // MARK: Teardown

    func dismiss() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for pane in panes { pane.window.orderOut(nil) }
        panes.removeAll()
        showCursor()
        onRegion = nil
        onWindow = nil
        onCancel = nil
    }

    // MARK: Cursor balance

    private func hideCursor() {
        guard !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    private func showCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    // MARK: Geometry

    private static func primaryHeight() -> CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
    }
}

extension NSScreen {
    /// The CoreGraphics display id backing this screen.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
