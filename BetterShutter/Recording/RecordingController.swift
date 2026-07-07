import AppKit
import AVFoundation

/// Starts/stops a screen recording and shows the floating control bar. Records the display under
/// the cursor to an MP4 in the save directory.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    private var engine: RecordingEngine?
    private var startTask: Task<Void, Never>?
    private let controlBar = RecordingControlBar()
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var startDate: Date?
    private var iconsHidden = false
    /// Whether the current recording writes into the user's save directory (After-Capture "Save"
    /// cell, sampled at start — the file's destination is chosen before recording begins).
    private var savesToDisk = true

    // Cursor-track capture for the editor's Follow-Mouse auto-zoom (full-display recordings only).
    private var cursorSamples: [CursorSample] = []
    private var cursorTimer: Timer?
    private var cursorDisplayFrame: CGRect = .zero
    var onStateChange: (() -> Void)?

    private init() {
        controlBar.onStop = { [weak self] in self?.stop() }
        controlBar.onTogglePause = { [weak self] in self?.togglePause() }
    }

    func toggle() { isRecording ? stop() : start() }

    func togglePause() {
        guard isRecording, let engine else { return }
        isPaused.toggle()
        if isPaused { engine.pause() } else { engine.resume() }
        controlBar.setPaused(isPaused)
    }

    func start() {
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        beginRecording(displayID: displayUnderMouse(), sourceRect: nil, gif: false)
    }

    func startRegion(displayID: CGDirectDisplayID, sourceRectPoints: CGRect) {
        beginRecording(displayID: displayID, sourceRect: sourceRectPoints, gif: false)
    }

    /// Record a single window, following it across the screen. `displayID` is just for the overlays
    /// (click highlight / webcam / keystrokes); the recording itself tracks the window.
    func startWindow(windowID: CGWindowID, displayID: CGDirectDisplayID) {
        beginRecording(displayID: displayID, sourceRect: nil, gif: false, windowID: windowID)
    }

    func startGIF() {
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        beginRecording(displayID: displayUnderMouse(), sourceRect: nil, gif: true)
    }

    /// Stop if recording, otherwise start a GIF recording.
    func toggleGIF() { isRecording ? stop() : startGIF() }

    private func beginRecording(displayID: CGDirectDisplayID, sourceRect: CGRect?, gif: Bool,
                                windowID: CGWindowID? = nil) {
        guard !isRecording else { return }
        savesToDisk = Preferences.afterCaptureActions(for: .recording).contains(.save)
        let url = Self.recordingURL(ext: gif ? "gif" : "mp4", toSaveDirectory: savesToDisk)
        if !gif { Preferences.recordingInProgressPath = url.path } // for crash recovery
        let engine = RecordingEngine()
        engine.captureSystemAudio = Preferences.recordSystemAudio
        engine.captureMicrophone = Preferences.recordMicrophone && !gif
        engine.showsCursor = Preferences.showCursorInRecording
        engine.fps = Preferences.recordingFPS
        engine.gifMode = gif
        self.engine = engine
        isRecording = true
        isPaused = false
        startDate = Date()
        controlBar.show(canPause: !gif)
        // Hide desktop icons for the whole recording (kept in the capture, removed on stop).
        if Preferences.hideDesktopIcons { DesktopIconHider.shared.hide(); iconsHidden = true }
        // Capture a cursor track for full-display recordings (region/window coords wouldn't map).
        cursorSamples = []
        if sourceRect == nil, windowID == nil, !gif,
           let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            cursorDisplayFrame = screen.frame
            startCursorSampling()
        }
        // Keep our own control bar out of the recording (overlays stay in deliberately).
        engine.excludedWindowIDs = [controlBar.windowID].compactMap { $0 }
        FocusController.run(shortcutNamed: Preferences.focusShortcutStart)
        if Preferences.highlightClicks { ClickHighlighter.shared.start(displayID: displayID) }
        if !gif, Preferences.showWebcam { WebcamOverlay.shared.start(displayID: displayID) }
        if !gif, Preferences.showKeystrokes { KeystrokeOverlay.shared.start(displayID: displayID) }
        onStateChange?()

        startTask = Task {
            // Await mic authorization before capture so the first recording actually gets mic audio.
            if engine.captureMicrophone {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if !granted { engine.captureMicrophone = false }
            }
            do {
                if let windowID {
                    try await engine.start(windowID: windowID, to: url)
                } else {
                    try await engine.start(displayID: displayID, sourceRect: sourceRect, to: url)
                }
            } catch {
                isRecording = false
                isPaused = false
                startDate = nil
                Preferences.recordingInProgressPath = nil
                controlBar.hide()
                ClickHighlighter.shared.stop()
                WebcamOverlay.shared.stop()
                KeystrokeOverlay.shared.stop()
                stopCursorSampling()
                FocusController.run(shortcutNamed: Preferences.focusShortcutStop)
                if iconsHidden { DesktopIconHider.shared.show(); iconsHidden = false }
                self.engine = nil
                onStateChange?()
                showError(error)
            }
        }
    }

    func stop() {
        guard isRecording, let engine else { return }
        isRecording = false
        isPaused = false
        startDate = nil
        controlBar.hide()
        ClickHighlighter.shared.stop()
        WebcamOverlay.shared.stop()
        KeystrokeOverlay.shared.stop()
        stopCursorSampling()
        FocusController.run(shortcutNamed: Preferences.focusShortcutStop)
        if iconsHidden { DesktopIconHider.shared.show(); iconsHidden = false }
        self.engine = nil
        onStateChange?()

        let startTask = self.startTask
        self.startTask = nil
        let track = cursorSamples.isEmpty ? nil : CursorTrack(samples: cursorSamples)
        let saved = savesToDisk
        Task {
            // Ensure start() (and its startCapture) finished before stopping, so the SCStream
            // is actually torn down and never leaks.
            await startTask?.value
            let url = await engine.stop()
            Preferences.recordingInProgressPath = nil
            guard let url else { return }
            track?.write(for: url)
            Task.detached(priority: .utility) { CaptureHistoryStore.add(fileURL: url) }

            let actions = Preferences.afterCaptureActions(for: .recording)
            if actions.contains(.copy) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([url as NSURL])
            }
            if actions.contains(.upload), CloudUploadService.isEnabled {
                CloudUploadService.uploadFile(url)
            }
            // The trim window is AVFoundation-based and can't decode GIF — never route GIFs there.
            let isGIF = url.pathExtension.lowercased() == "gif"
            if actions.contains(.videoEditor), !isGIF {
                CaptureCoordinator.shared.editVideo(url: url)
            }
            if actions.contains(.quickAccess) {
                CaptureCoordinator.shared.showRecordingPreview(url: url, saved: saved)
            } else if saved || !actions.contains(.videoEditor) || isGIF {
                // No quick-access card to act from — fall back to revealing the file. An unsaved
                // recording that isn't showing in the editor must still surface SOMEWHERE, or it
                // sits invisibly in the unsaved-recordings folder.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Hard backstop: 25 Hz × 1 h ≈ 90k samples ≈ 2 MB of structs. With stationary-run dedupe
    /// below this is effectively unreachable in real recordings.
    private static let maxCursorSamples = 90_000

    private func startCursorSampling() {
        let start = startDate ?? Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.cursorDisplayFrame.width > 0 else { return }
                guard self.cursorSamples.count < Self.maxCursorSamples else {
                    self.stopCursorSampling()
                    return
                }
                let m = NSEvent.mouseLocation
                let f = self.cursorDisplayFrame
                let x = min(max(0, (m.x - f.minX) / f.width), 1)
                let y = min(max(0, (m.y - f.minY) / f.height), 1)
                let sample = CursorSample(t: Date().timeIntervalSince(start), x: Double(x), y: Double(y))
                // Run-length dedupe: while the cursor is stationary keep only the run's first and
                // last sample, sliding the last one's timestamp forward — lossless for the trim
                // window's linear interpolation, and an idle mouse costs 2 samples instead of 25/s.
                let n = self.cursorSamples.count
                if n >= 2,
                   self.cursorSamples[n - 1].x == sample.x, self.cursorSamples[n - 1].y == sample.y,
                   self.cursorSamples[n - 2].x == sample.x, self.cursorSamples[n - 2].y == sample.y {
                    self.cursorSamples[n - 1] = sample
                } else {
                    self.cursorSamples.append(sample)
                }
            }
        }
        timer.tolerance = 0.008
        cursorTimer = timer
    }

    private func stopCursorSampling() { cursorTimer?.invalidate(); cursorTimer = nil }

    // MARK: Helpers

    /// Recordings share the screenshot filename template (mp4/gif extension, "Recording" mode tag).
    /// With the After-Capture "Save" cell off, the file records into a durable scratch folder in
    /// Application Support instead (NOT the temp directory — crash recovery and the card's
    /// Save/Edit actions must outlive macOS's periodic temp purge). It still feeds the history
    /// archive, clipboard, upload, and quick-access card, and the card's Save button can copy it
    /// into the save directory later. Old scratch files are pruned after a week.
    private static func recordingURL(ext: String, toSaveDirectory: Bool) -> URL {
        let dir: URL
        if toSaveDirectory {
            dir = Preferences.saveDirectory
        } else {
            dir = unsavedRecordingsDirectory
            pruneOldUnsavedRecordings(in: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = FilenameTemplate.render(
            Preferences.filenameTemplate,
            modeTag: "Recording",
            fileExtension: ext,
            counter: Preferences.nextCaptureCounter()
        )
        return FileSaver.uniqueURL(in: dir, filename: filename)
    }

    private static var unsavedRecordingsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BetterShutter/Unsaved Recordings", isDirectory: true)
    }

    /// Unsaved recordings live outside the temp directory so nothing purges them behind the
    /// user's back mid-session — so we do our own housekeeping instead (a week is plenty for
    /// "I closed the card but still want the file back").
    private static func pruneOldUnsavedRecordings(in dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for item in items {
            if let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               modified < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }

    private func displayUnderMouse() -> CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return screen?.displayID ?? CGMainDisplayID()
    }

    private func showError(_ error: Error) {
        if PermissionsService.shared.handleCaptureError(error) { return }
        let alert = NSAlert()
        alert.messageText = "Recording Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
