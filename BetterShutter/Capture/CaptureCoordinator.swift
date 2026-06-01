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

    /// The last region selection (global rect + display), for "Capture Previous Area".
    private var lastRegion: (rect: CGRect, displayID: CGDirectDisplayID)?

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
            beginRegionCapture()
        }
    }

    /// Select a region and run on-device OCR, copying the recognized text to the clipboard.
    func captureText() {
        guard !isCapturing, !overlay.isPresenting else { return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        isCapturing = true
        Task {
            do {
                let frozen = try await engine.freezeAllDisplays()
                let content = try await engine.shareableContent()
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: false,
                    onRegion: { [weak self] image, _, _, _ in self?.recognizeText(image) },
                    onWindow: { [weak self] _ in self?.isCapturing = false },
                    onCancel: { [weak self] in self?.isCapturing = false }
                )
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    /// Select a region, lift the foreground subject out of it as a transparent PNG (auto-cropped).
    func captureCutout() {
        guard !isCapturing, !overlay.isPresenting else { return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        isCapturing = true
        Task {
            do {
                let frozen = try await engine.freezeAllDisplays()
                let content = try await engine.shareableContent()
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: false,
                    onRegion: { [weak self] image, _, _, _ in self?.performCutout(image) },
                    onWindow: { [weak self] _ in self?.isCapturing = false },
                    onCancel: { [weak self] in self?.isCapturing = false }
                )
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    private func performCutout(_ image: CapturedImage) {
        isCapturing = false
        HUD.show("Extracting subject…", duration: 0.8)
        Task {
            guard let cut = await ObjectCutout.cutout(image) else {
                HUD.show("No subject found")
                return
            }
            finish(cut, mode: .region)
        }
    }

    /// Scrolling capture: select a window/region, scroll, and stitch the frames into one tall image.
    /// (Implemented in ScrollingCaptureController; this is the entry point.)
    func captureScrolling() {
        ScrollingCaptureController.shared.begin()
    }

    /// Count down, then capture the full screen — lets the user open menus / hover states first.
    func captureFullScreenAfter(_ seconds: Int) {
        SelfTimer.shared.run(seconds: seconds) { [weak self] in self?.capture(.fullDisplay) }
    }

    /// Re-capture the exact region from the previous selection, with no overlay.
    func captureLastRegion() {
        guard !isCapturing, !overlay.isPresenting else { return }
        guard let last = lastRegion else { HUD.show("No previous area"); return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == last.displayID }) else { return }
        let frame = screen.frame
        // Global (bottom-left) rect → display-local top-left points for SCStream.
        let localTopLeft = CGRect(
            x: last.rect.minX - frame.minX,
            y: frame.maxY - last.rect.maxY,
            width: last.rect.width,
            height: last.rect.height
        )
        isCapturing = true
        Task {
            do {
                let image = try await engine.captureRegion(displayID: last.displayID, sourceRectPoints: localTopLeft)
                finish(image, mode: .region)
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    /// Select a region, then start recording just that region to an MP4.
    func recordRegion() {
        guard !isCapturing, !overlay.isPresenting, !RecordingController.shared.isRecording else { return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        isCapturing = true
        Task {
            do {
                let frozen = try await engine.freezeAllDisplays()
                let content = try await engine.shareableContent()
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: false,
                    onRegion: { [weak self] _, globalRect, displayID, _ in
                        self?.startRegionRecording(globalRect: globalRect, displayID: displayID)
                    },
                    onWindow: { [weak self] _ in self?.isCapturing = false },
                    onCancel: { [weak self] in self?.isCapturing = false }
                )
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    private func startRegionRecording(globalRect: CGRect, displayID: CGDirectDisplayID) {
        isCapturing = false
        lastRegion = (globalRect, displayID)
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        let frame = screen.frame
        // SCStream sourceRect is in display-local points, top-left origin.
        let localTopLeft = CGRect(
            x: globalRect.minX - frame.minX,
            y: frame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
        RecordingController.shared.startRegion(displayID: displayID, sourceRectPoints: localTopLeft)
    }

    // MARK: Flows

    /// Region / window capture with the CleanShot-style action bar. The bar lets the user pick the
    /// outcome (capture / annotate / copy / save / record) per selection instead of always running
    /// the configured default. A window click has no bar and uses the configured after-action.
    private func beginRegionCapture() {
        isCapturing = true
        Task {
            do {
                let frozen = try await engine.freezeAllDisplays()
                let content = try await engine.shareableContent()
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: Preferences.magnifierEnabled,
                    toolbarActions: [.capture, .annotate, .copy, .save, .record],
                    onRegion: { [weak self] image, globalRect, displayID, action in
                        self?.handleRegionAction(image, globalRect: globalRect, displayID: displayID, action: action)
                    },
                    onWindow: { [weak self] id in self?.captureWindow(id) },
                    onCancel: { [weak self] in self?.isCapturing = false }
                )
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    private func handleRegionAction(_ rawImage: CapturedImage, globalRect: CGRect, displayID: CGDirectDisplayID, action: OverlayAction) {
        isCapturing = false
        lastRegion = (globalRect, displayID)
        // Apply the Retina→1× setting once up front so every action-bar path (annotate / copy /
        // save) is consistent with the default capture flow, not just `.capture`.
        let image = outputImage(rawImage)
        switch action {
        case .capture:
            finish(image, mode: .region)
        case .annotate:
            CaptureHistory.shared.add(image, mode: .region)
            edit(image, mode: .region)
        case .copy:
            CaptureHistory.shared.add(image, mode: .region)
            PasteboardWriter.copy(image.cgImage)
            if Preferences.captureSoundEnabled { NSSound(named: "Grab")?.play() }
            HUD.show("Copied")
        case .save:
            CaptureHistory.shared.add(image, mode: .region)
            Task {
                let url = await Task.detached { try? FileSaver.save(image.cgImage, mode: .region) }.value
                HUD.show(url != nil ? "Saved" : "Save failed")
            }
        case .record:
            startRegionRecording(globalRect: globalRect, displayID: displayID)
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

    /// Apply the Retina→1× downscale option (no-op when disabled or already 1×). Idempotent: a
    /// second call is a no-op since the result's scale is 1.
    private func outputImage(_ image: CapturedImage) -> CapturedImage {
        guard Preferences.downscaleRetina, image.scale > 1,
              let scaled = ImageScaler.downscaled(image.cgImage, by: image.scale) else { return image }
        return CapturedImage(cgImage: scaled, scale: 1, displayID: image.displayID)
    }

    private func finish(_ image: CapturedImage, mode: CaptureMode) {
        isCapturing = false
        let output = outputImage(image)
        CaptureHistory.shared.add(output, mode: mode)
        let action = Preferences.afterCaptureAction
        if action.copies { PasteboardWriter.copy(output.cgImage) }
        if Preferences.captureSoundEnabled { NSSound(named: "Grab")?.play() }

        Task {
            // Always persist a durable file; reveal it from the preview.
            let url = await Task.detached { try? FileSaver.save(output.cgImage, mode: mode) }.value
            if action.previews {
                preview.show(output, mode: mode, savedURL: url)
            }
        }
    }

    /// Deliver an externally-produced capture (scrolling stitch, etc.) through the normal output
    /// pipeline: history + copy/save/preview per the configured after-capture action.
    func deliver(_ image: CapturedImage, mode: CaptureMode) {
        finish(image, mode: mode)
    }

    /// Re-show the float preview for a capture from history.
    func reopenPreview(_ item: CaptureHistory.Item) {
        preview.show(item.image, mode: item.mode, savedURL: nil)
    }

    func edit(_ image: CapturedImage, mode: CaptureMode) {
        let controller = EditorWindowController(image: image, mode: mode)
        controller.onClose = { [weak self] in self?.editor = nil }
        editor = controller
        controller.present()
    }

    /// Open the editor on a base image plus restored annotation layers (from a `.bsproj` project).
    func editProject(_ image: CapturedImage, elements: [AnnotationElement]) {
        let controller = EditorWindowController(image: image, mode: .region, elements: elements)
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
