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

    /// The last region selection (global rect + display), for "Capture Previous Area". Persisted to
    /// `Preferences` so it survives relaunches.
    private var lastRegion: (rect: CGRect, displayID: CGDirectDisplayID)? {
        get { Preferences.lastRegion.map { ($0.rect, $0.displayID) } }
        set { Preferences.lastRegion = newValue.map { StoredRegion(rect: $0.rect, displayID: $0.displayID) } }
    }

    private init() {
        preview.onAnnotate = { [weak self] image, mode in self?.edit(image, mode: mode) }
        preview.onBeautify = { [weak self] image, mode in self?.beautify(image, mode: mode) }
    }

    /// Freeze all displays, momentarily hiding desktop icons first when the user enabled it, so the
    /// frozen bitmap (and thus the selection and capture) shows a clean desktop.
    private func frozenDisplays() async throws -> [CapturedImage] {
        let hideIcons = Preferences.hideDesktopIcons
        if hideIcons {
            DesktopIconHider.shared.hide()
            try? await Task.sleep(for: .milliseconds(50))
        }
        defer { if hideIcons { DesktopIconHider.shared.show() } }
        return try await engine.freezeAllDisplays()
    }

    /// If a self-timer delay is configured, show the countdown and return `true` so the caller aborts;
    /// `resume` re-invokes the capture (with the delay already consumed) when the countdown elapses.
    /// Returns `false` when no delay is set, so the caller proceeds immediately.
    private func startCountdownIfNeeded(_ resume: @escaping () -> Void) -> Bool {
        let seconds = Preferences.captureDelaySeconds
        guard seconds > 0 else { return false }
        CaptureCountdown.shared.run(seconds: seconds, onComplete: resume)
        return true
    }

    /// Legacy mode-based entry (URL scheme / Shortcuts): region and window now share the one merged
    /// screenshot flow; only full-display still captures directly.
    func capture(_ mode: CaptureMode, afterDelay: Bool = true) {
        switch mode {
        case .region, .window:
            captureScreenshot(afterDelay: afterDelay)
        case .fullDisplay:
            guard !isCapturing, !overlay.isPresenting, !CaptureCountdown.shared.isActive else { return }
            guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
            if afterDelay, startCountdownIfNeeded({ [weak self] in self?.capture(mode, afterDelay: false) }) { return }
            sampleBypass()
            captureFullDisplay()
        }
    }

    /// The one merged screenshot flow (Quick Screenshot + Capture Region + Capture Window): drag a
    /// selection and it's delivered straight to the normal output (quick-access card + clipboard per
    /// settings) with no action-bar step; hold Space to highlight and click a window instead.
    func captureScreenshot(afterDelay: Bool = true) {
        guard !isCapturing, !overlay.isPresenting, !CaptureCountdown.shared.isActive else { return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        if afterDelay, startCountdownIfNeeded({ [weak self] in self?.captureScreenshot(afterDelay: false) }) { return }
        sampleBypass()
        presentRegion(
            magnifier: Preferences.magnifierEnabled,
            onRegion: { [weak self] image, rect, displayID in
                guard let self else { return }
                self.isCapturing = false
                self.sampleBypass()              // Shift may still be held at confirm
                self.lastRegion = (rect, displayID)
                self.finish(image, mode: .region)
            },
            onWindow: { [weak self] id in self?.captureWindow(id) }
        )
    }

    /// Screenshot & markup (macshot-style): select a region (or hold Space and click a window), then
    /// open the full editor with every annotation / drawing tool ready, instead of a quick-access card.
    func captureAndEdit(afterDelay: Bool = true) {
        guard !isCapturing, !overlay.isPresenting, !CaptureCountdown.shared.isActive else { return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        if afterDelay, startCountdownIfNeeded({ [weak self] in self?.captureAndEdit(afterDelay: false) }) { return }
        sampleBypass()
        presentRegion(
            magnifier: Preferences.magnifierEnabled,
            onRegion: { [weak self] image, rect, displayID in
                guard let self else { return }
                self.isCapturing = false
                self.lastRegion = (rect, displayID)
                let output = self.outputImage(image)
                CaptureHistory.shared.add(output, mode: .region)
                self.edit(output, mode: .region)
            },
            onWindow: { [weak self] id in self?.captureWindowAndEdit(id) }
        )
    }

    /// Region overlay with a single outcome (no action bar). `onRegion` receives the cropped image
    /// plus its global rect + display; `onWindow` fires when the user Space-clicks a window instead.
    private func presentRegion(
        magnifier: Bool,
        onRegion: @escaping (CapturedImage, CGRect, CGDirectDisplayID) -> Void,
        onWindow: @escaping (CGWindowID) -> Void
    ) {
        isCapturing = true
        Task {
            do {
                let frozen = try await frozenDisplays()
                let content = try await engine.shareableContent()
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: magnifier,
                    windowSelection: true,
                    windowPickRequiresSpace: true,   // hold Space to switch to window pick
                    instantCapture: true,   // release the drag = capture immediately, no extra confirm
                    onRegion: { image, rect, displayID, _ in onRegion(image, rect, displayID) },
                    onWindow: onWindow,
                    onCancel: { [weak self] in self?.isCapturing = false }
                )
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    private func captureWindowAndEdit(_ id: CGWindowID) {
        Task {
            do {
                let image = try await engine.captureWindow(id)
                isCapturing = false
                let output = outputImage(image)
                CaptureHistory.shared.add(output, mode: .window)
                edit(output, mode: .window)
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    /// Select a region and run on-device OCR, copying the recognized text to the clipboard.
    func captureText() {
        guard !isCapturing, !overlay.isPresenting else { return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        isCapturing = true
        Task {
            do {
                let frozen = try await frozenDisplays()
                let content = try await engine.shareableContent()
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: false,
                    instantCapture: true,   // release the drag = OCR immediately, no action bar
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
                let frozen = try await frozenDisplays()
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

    /// Re-capture the exact region from the previous selection, with no overlay.
    func captureLastRegion() {
        guard !isCapturing, !overlay.isPresenting else { return }
        guard let last = lastRegion else { HUD.show("No previous area"); return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        sampleBypass()
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
                let frozen = try await frozenDisplays()
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

    /// Click a window to record just that window (it's followed across the screen). A drag instead
    /// records that region, so the one flow covers both.
    func recordWindow() {
        guard !isCapturing, !overlay.isPresenting, !RecordingController.shared.isRecording else { return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        isCapturing = true
        Task {
            do {
                let frozen = try await frozenDisplays()
                let content = try await engine.shareableContent()
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: false,
                    windowSelection: true,
                    onRegion: { [weak self] _, globalRect, displayID, _ in
                        self?.startRegionRecording(globalRect: globalRect, displayID: displayID)
                    },
                    onWindow: { [weak self] id in self?.startWindowRecording(id) },
                    onCancel: { [weak self] in self?.isCapturing = false }
                )
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    private func startWindowRecording(_ id: CGWindowID) {
        isCapturing = false
        RecordingController.shared.startWindow(windowID: id, displayID: Self.displayUnderMouse())
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
    /// All-in-One (CleanShot-style): one entry that selects a region or window with the full action
    /// bar (capture / annotate / copy / save / record) and restores your last selection so you can
    /// re-shoot the same area with a single Return. Shift still locks the drag to a square.
    func captureAllInOne(afterDelay: Bool = true) {
        guard !isCapturing, !overlay.isPresenting, !CaptureCountdown.shared.isActive else { return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        if afterDelay, startCountdownIfNeeded({ [weak self] in self?.captureAllInOne(afterDelay: false) }) { return }
        isCapturing = true
        let restore = lastRegion?.rect
        Task {
            do {
                let frozen = try await frozenDisplays()
                let content = try await engine.shareableContent()
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: Preferences.magnifierEnabled,
                    windowSelection: true,
                    toolbarActions: [.capture, .annotate, .copy, .save, .record],
                    restoreSelection: restore,
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
        sampleBypass()   // Shift is still held at overlay confirm
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
            Task {
                let png = await Task.detached { ImageEncoder.encode(image.cgImage, as: .png) }.value
                if let png { PasteboardWriter.copy(png: png) }
                if Preferences.captureSoundEnabled { NSSound(named: "Grab")?.play() }
                HUD.show(png != nil ? "Copied" : "Copy failed")
            }
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
            let barcodes = await BarcodeDetector.detect(image)
            guard !text.isEmpty || !barcodes.isEmpty else { HUD.show("No text found"); return }
            if !text.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // Keychain round-trip off the main thread; the store itself honors the toggle.
                Task.detached(priority: .utility) { OCRHistoryStore.add(text) }
            }
            if Preferences.captureSoundEnabled { NSSound(named: "Grab")?.play() }
            OCRResultWindowController.shared.show(text: text, barcodes: barcodes)
        }
    }

    private func captureFullDisplay() {
        isCapturing = true
        let displayID = Self.displayUnderMouse()
        Task {
            do {
                let hideIcons = Preferences.hideDesktopIcons
                if hideIcons {
                    DesktopIconHider.shared.hide()
                    try? await Task.sleep(for: .milliseconds(50))
                }
                // Every connected display is captured; the one under the mouse goes through the
                // full pipeline (clipboard / preview / upload), the rest are archived and saved.
                let images: [CapturedImage]
                do { images = try await engine.freezeAllDisplays() }
                catch { if hideIcons { DesktopIconHider.shared.show() }; throw error }
                if hideIcons { DesktopIconHider.shared.show() }
                guard let main = images.first(where: { $0.displayID == displayID }) ?? images.first else {
                    throw CaptureError.noDisplays
                }
                for image in images where image.displayID != main.displayID {
                    saveSecondaryDisplay(image)
                }
                finish(main, mode: .fullDisplay)
            } catch {
                isCapturing = false
                handleError(error)
            }
        }
    }

    /// Output path for the non-focused displays of a full-screen capture: history + auto-save,
    /// but no clipboard/preview/upload — those belong to the display under the mouse.
    private func saveSecondaryDisplay(_ image: CapturedImage) {
        let output = autoBeautified(outputImage(image))
        CaptureHistory.shared.add(output, mode: .fullDisplay)
        guard Preferences.saveScreenshotsToDisk else { return }
        Task.detached { _ = try? FileSaver.save(output.cgImage, mode: .fullDisplay) }
    }

    // MARK: Output

    /// Apply the Retina→1× downscale option (no-op when disabled or already 1×). Idempotent: a
    /// second call is a no-op since the result's scale is 1.
    private func outputImage(_ image: CapturedImage) -> CapturedImage {
        guard Preferences.downscaleRetina, image.scale > 1,
              let scaled = ImageScaler.downscaled(image.cgImage, by: image.scale) else { return image }
        return CapturedImage(cgImage: scaled, scale: 1, displayID: image.displayID)
    }

    /// Shift held at the moment of the capture gesture bypasses beautify auto-apply for that shot.
    /// Sampled synchronously at the trigger because `finish()` runs later (after async capture).
    private var bypassBeautify = false

    private func sampleBypass() { bypassBeautify = NSEvent.modifierFlags.contains(.shift) }

    /// Auto-apply the default beautify preset (CleanShot-style), unless Shift bypassed it.
    private func autoBeautified(_ image: CapturedImage) -> CapturedImage {
        guard !bypassBeautify,
              let name = Preferences.autoBeautifyPresetName,
              let preset = Preferences.beautifyPresets.first(where: { $0.name == name }) else { return image }
        let style = preset.applied(to: .makeDefault())
        guard let cg = BeautifyRenderer.render(base: image.cgImage, style: style) else { return image }
        return CapturedImage(cgImage: cg, scale: 1, displayID: image.displayID)
    }

    private func finish(_ image: CapturedImage, mode: CaptureMode) {
        isCapturing = false
        let output = autoBeautified(outputImage(image))
        CaptureHistory.shared.add(output, mode: mode)
        let action = Preferences.afterCaptureAction
        if Preferences.captureSoundEnabled { NSSound(named: "Grab")?.play() }
        let wantsUpload = Preferences.uploadAfterCapture && CloudUploadService.isEnabled
        let format = Preferences.format
        let savesToDisk = Preferences.saveScreenshotsToDisk

        Task {
            // Encode PNG once, off the main thread; the bytes are shared by the clipboard, the
            // upload, and (when the save format is PNG) the file on disk. A Retina 5K frame is a
            // ~60 MB bitmap — encoding it repeatedly, on the main thread, stalls the UI.
            let needsPNG = action.copies || wantsUpload || (format == .png && savesToDisk)
            let png: Data? = needsPNG
                ? await Task.detached { ImageEncoder.encode(output.cgImage, as: .png) }.value
                : nil
            if action.copies, let png { PasteboardWriter.copy(png: png) }
            // Auto-upload + copy the share link (overwrites the image on the pasteboard, CleanShot-style).
            if wantsUpload {
                if let png { CloudUploadService.upload(png: png) } else { HUD.show("Encode failed") }
            }
            // Persist a durable file when auto-save is on; reveal it from the preview. With
            // auto-save off the capture still lives in the history archive and on the pasteboard.
            let url: URL?
            if !savesToDisk {
                url = nil
            } else if format == .png, let png {
                url = await Task.detached { try? FileSaver.write(png, format: .png, mode: mode) }.value
            } else {
                url = await Task.detached { try? FileSaver.save(output.cgImage, mode: mode) }.value
            }
            if action.previews {
                preview.show(output, mode: mode, savedURL: url)
            }
        }
    }

    /// Deliver an externally-produced capture (scrolling stitch, etc.) through the normal output
    /// pipeline: history + copy/save/preview per the configured after-capture action.
    func deliver(_ image: CapturedImage, mode: CaptureMode) {
        sampleBypass()
        finish(image, mode: mode)
    }

    /// Re-show the float preview for a capture from history.
    func reopenPreview(_ item: CaptureHistory.Item) {
        preview.show(item.image, mode: item.mode, savedURL: nil)
    }

    /// Re-show a saved capture as a quick-access card (Capture History "Restore").
    func reopenPreview(_ image: CapturedImage, mode: CaptureMode, savedURL: URL?) {
        preview.show(image, mode: mode, savedURL: savedURL)
    }

    /// Restore the most recently dismissed quick-access card.
    func restoreClosedPreview() {
        preview.reopenLastClosed()
    }

    func edit(_ image: CapturedImage, mode: CaptureMode) {
        let controller = EditorWindowController(image: image, mode: mode)
        install(editor: controller)
    }

    /// Open the editor on a base image plus restored annotation layers (from a `.bsproj` project).
    func editProject(_ image: CapturedImage, elements: [AnnotationElement]) {
        let controller = EditorWindowController(image: image, mode: .region, elements: elements)
        install(editor: controller)
    }

    /// Close any previous editor before taking ownership of the new one, and only clear the
    /// reference if it still points at the closing controller — otherwise a lingering old window's
    /// close would orphan (and leak the full-res image + undo stack of) the current editor.
    private func install(editor controller: EditorWindowController) {
        editor?.close()
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.editor === controller else { return }
            self.editor = nil
        }
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
