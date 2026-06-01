import AppKit

/// The single entry point menu items and hotkeys call. Orchestrates: permission gate → freeze →
/// overlay (region/window) or direct capture (full display) → output (copy / save / preview).
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private let engine = CaptureEngine()
    private let overlay = OverlayController()
    private let preview = FloatPreviewController()
    private var editor: EditorWindowController?
    private var beautifier: BeautifyWindowController?
    private var isCapturing = false

    private init() {
        preview.onAnnotate = { [weak self] image, mode in self?.edit(image, mode: mode) }
        preview.onBeautify = { [weak self] image, mode in self?.beautify(image, mode: mode) }
    }

    func capture(_ mode: CaptureMode) {
        guard !isCapturing, !overlay.isPresenting else { return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }

        switch mode {
        case .fullDisplay:
            captureFullDisplay()
        case .region, .window:
            presentOverlay()
        }
    }

    // MARK: Flows

    private func presentOverlay() {
        isCapturing = true
        Task {
            do {
                let frozen = try await engine.freezeAllDisplays()
                let content = try await engine.shareableContent()
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: Preferences.magnifierEnabled,
                    onRegion: { [weak self] image in self?.finish(image, mode: .region) },
                    onWindow: { [weak self] id in self?.captureWindow(id) },
                    onCancel: { [weak self] in self?.isCapturing = false }
                )
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    private func captureWindow(_ id: CGWindowID) {
        Task {
            do {
                let image = try await engine.captureWindow(id)
                finish(image, mode: .window)
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    private func captureFullDisplay() {
        isCapturing = true
        let displayID = Self.displayUnderMouse()
        Task {
            do {
                let image = try await engine.captureDisplay(displayID)
                finish(image, mode: .fullDisplay)
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    // MARK: Output

    private func finish(_ image: CapturedImage, mode: CaptureMode) {
        isCapturing = false
        let action = Preferences.afterCaptureAction
        if action.copies { PasteboardWriter.copy(image.cgImage) }
        if Preferences.captureSoundEnabled { NSSound(named: "Grab")?.play() }

        Task {
            // Always persist a durable file; reveal it from the preview.
            let url = await Task.detached { try? FileSaver.save(image.cgImage, mode: mode) }.value
            if action.previews {
                preview.show(image, mode: mode, savedURL: url)
            }
        }
    }

    func edit(_ image: CapturedImage, mode: CaptureMode) {
        let controller = EditorWindowController(image: image, mode: mode)
        controller.onClose = { [weak self] in self?.editor = nil }
        editor = controller
        controller.present()
    }

    func beautify(_ image: CapturedImage, mode: CaptureMode) {
        let controller = BeautifyWindowController(image: image, mode: mode)
        controller.onClose = { [weak self] in self?.beautifier = nil }
        beautifier = controller
        controller.present()
    }

    private func handleError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Capture Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Geometry

    private static func displayUnderMouse() -> CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return screen?.displayID ?? CGMainDisplayID()
    }
}
