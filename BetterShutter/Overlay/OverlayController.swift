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
    private var escMonitor: Any?

    private var onRegion: ((CapturedImage, CGRect, CGDirectDisplayID, OverlayAction) -> Void)?
    private var onWindow: ((CGWindowID) -> Void)?
    private var onCancel: (() -> Void)?

    var isPresenting: Bool { !panes.isEmpty }

    // MARK: Present

    func present(
        frozen: [CapturedImage],
        windows: [WindowInfo],
        magnifierEnabled: Bool,
        windowSelection: Bool = true,
        windowPickRequiresSpace: Bool = false,
        toolbarActions: [OverlayAction] = [],
        instantCapture: Bool = false,
        lockedAspect: CGFloat? = nil,
        restoreSelection: CGRect? = nil,
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

            // The frozen bitmap goes straight into a layer's contents: the ScreenCaptureKit image is
            // IOSurface-backed, so this is zero-copy to the window server. An NSImageView would
            // re-render it into its own screen-sized backing store (~60 MB per Retina 5K display).
            let background = NSView(frame: container.bounds)
            background.wantsLayer = true
            background.autoresizingMask = [.width, .height]
            background.layer?.contents = image.cgImage
            background.layer?.contentsGravity = .resize
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
            view.lockedAspect = lockedAspect
            // Restore the prior selection on the pane whose screen holds it (global → view coords).
            if let restore = restoreSelection, frame.intersects(restore) {
                view.initialSelection = CGRect(
                    x: restore.minX - frame.minX,
                    y: restore.minY - frame.minY,
                    width: restore.width,
                    height: restore.height
                )
            }
            view.setCursorHidden = { [weak self] hidden in hidden ? self?.hideCursor() : self?.showCursor() }
            // Empty hits → no window hover-highlight and no click-to-pick (region-only flows).
            view.windowHits = windowSelection
                ? WindowHighlighter.viewRects(windows: windows, primaryHeight: primaryHeight, screenGlobalFrame: frame)
                : []
            view.windowPickRequiresSpace = windowPickRequiresSpace
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
        // The magnifier draws its own loupe in place of the pointer, so hide the system cursor then.
        // Otherwise the OverlayView sets a context-appropriate cursor (crosshair / pointing hand / …).
        if magnifierEnabled { hideCursor() }

        // Esc must always cancel, even if the key window / first responder isn't the pane the user
        // expects (wrong display, lost focus). A local monitor catches Esc anywhere in the app for the
        // whole presentation; a global one catches it if focus slipped to another app.
        installEscMonitor()

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
        // `cropping(to:)` only references the parent bitmap — handing it out as-is would pin the
        // whole ~60 MB frozen screen frame in memory for as long as the capture lives (history,
        // preview, editor). Re-render into a right-sized bitmap so the frame frees on dismiss.
        let detached = Self.detachedCopy(of: cropped)
        onRegion?(CapturedImage(cgImage: detached, scale: pane.image.scale, displayID: pane.image.displayID),
                  globalRect, displayID, action)
    }

    /// A deep copy backed by its own, crop-sized buffer (BGRA, matching ScreenCaptureKit output).
    private static func detachedCopy(of image: CGImage) -> CGImage {
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
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

    // MARK: Esc-always-cancels

    private func installEscMonitor() {
        removeEscMonitor()
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            MainActor.assumeIsolated { self?.handleCancel() }
            return nil   // swallow
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.handleCancel() }
        }
        escMonitor = [local, global].compactMap { $0 }
    }

    private func removeEscMonitor() {
        if let monitors = escMonitor as? [Any] { monitors.forEach { NSEvent.removeMonitor($0) } }
        escMonitor = nil
    }

    // MARK: Teardown

    func dismiss() {
        removeEscMonitor()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for pane in panes {
            // Break the retain cycle view → onRegionSelected closure → pane → view/window/image.
            // Without this every presentation leaks its overlay windows AND the frozen full-res
            // bitmaps (~60 MB per Retina 5K display), growing the footprint on each capture.
            pane.view.onRegionSelected = nil
            pane.view.onWindowSelected = nil
            pane.view.onCancel = nil
            pane.view.setCursorHidden = nil
            pane.window.orderOut(nil)
            pane.window.contentView = nil
        }
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
