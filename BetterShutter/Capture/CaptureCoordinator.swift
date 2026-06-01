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
            presentOverlay { [weak self] image, mode in self?.finish(image, mode: mode) }
        }
    }

    /// Select a region and run on-device OCR, copying the recognized text to the clipboard.
    func captureText() {
        guard !isCapturing, !overlay.isPresenting else { return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        presentOverlay { [weak self] image, _ in self?.recognizeText(image) }
    }

    // MARK: Flows

    private func presentOverlay(completion: @escaping (CapturedImage, CaptureMode) -> Void) {
        isCapturing = true
        Task {
            do {
                let frozen = try await engine.freezeAllDisplays()
                let content = try await engine.shareableContent()
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: Preferences.magnifierEnabled,
                    onRegion: { image in completion(image, .region) },
                    onWindow: { [weak self] id in self?.captureWindow(id, completion: completion) },
                    onCancel: { [weak self] in self?.isCapturing = false }
                )
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    private func captureWindow(_ id: CGWindowID, completion: @escaping (CapturedImage, CaptureMode) -> Void) {
        Task {
            do {
                let image = try await engine.captureWindow(id)
                completion(image, .window)
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    private func recognizeText(_ image: CapturedImage) {
        isCapturing = false
        Task {
            let text = await TextRecognizer.recognize(image)
            guard !text.isEmpty else { HUD.show("No text found"); return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if Preferences.captureSoundEnabled { NSSound(named: "Grab")?.play() }
            HUD.show("Text copied")
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
