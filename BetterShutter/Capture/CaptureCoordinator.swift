import AppKit

/// The single entry point menu items and hotkeys call. Orchestrates: permission gate → freeze →
/// overlay (region/window) or direct capture (full display) → output (copy / save / preview).
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private let engine = CaptureEngine()
    private let overlay = OverlayController()
    private let preview = FloatPreviewController()
    private var isCapturing = false

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
