import AVFoundation
import AppKit

/// A circular webcam preview floated over the recorded display. ScreenCaptureKit records the whole
/// display including this window, so the camera is composited into the video with no per-frame work.
/// The bubble is draggable so the user can park it in any corner; it needs camera permission.
@MainActor
final class WebcamOverlay {
    static let shared = WebcamOverlay()

    /// AVCaptureSession isn't Sendable; box it so it can cross to the session queue safely. It is
    /// internally thread-safe, so `@unchecked Sendable` holds.
    private final class SessionBox: @unchecked Sendable { let session = AVCaptureSession() }

    private var window: NSWindow?
    private let box = SessionBox()
    private let sessionQueue = DispatchQueue(label: "app.bettershutter.webcam.session")
    private var configured = false
    private let size: CGFloat = 180

    func start(displayID: CGDirectDisplayID) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            Task { @MainActor in self?.present(displayID: displayID) }
        }
    }

    func stop() {
        window?.orderOut(nil)
        window = nil
        let box = self.box
        sessionQueue.async {
            if box.session.isRunning { box.session.stopRunning() }
        }
    }

    private func present(displayID: CGDirectDisplayID) {
        guard window == nil else { return }
        guard configureSessionIfNeeded() else { return }
        let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        let frame = NSRect(x: visible.maxX - size - 24, y: visible.minY + 24, width: size, height: size)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .screenSaver
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        host.layer?.cornerRadius = size / 2
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 3
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor

        let preview = AVCaptureVideoPreviewLayer(session: box.session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = host.bounds
        host.layer?.addSublayer(preview)
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window

        let box = self.box
        sessionQueue.async {
            if !box.session.isRunning { box.session.startRunning() }
        }
    }

    private func configureSessionIfNeeded() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let session = box.session
        session.beginConfiguration()
        session.sessionPreset = .medium
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        configured = true
        return true
    }
}
