import AppKit
import AVFoundation

/// Starts/stops a screen recording and shows the floating control bar. Records the display under
/// the cursor to an MP4 in the save directory.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    private var engine: RecordingEngine?
    private var startTask: Task<Void, Never>?
    /// TCC's requestAccess await is not cancellation-aware. Keep it separate from a recording
    /// session and retain the (possibly cancelled) task until the system prompt answers, so repeated
    /// hotkeys cannot accumulate engines/UI/finalizers waiting behind the same prompt.
    private var microphonePermissionTask: Task<Void, Never>?
    /// Bound retiring SCStream/writer work to one session. A new recording waits until the old
    /// start handshake and finalization have both unwound instead of accumulating hidden engines.
    private var finalizationTask: Task<Void, Never>?
    private var finalizationGeneration: UInt64 = 0
    /// Identity and destination of the UI-visible session. Stop A is allowed to overlap the start
    /// of B while A's writer finalizes, so every delayed callback must prove it still owns state.
    private var activeSessionID: UUID?
    private var activeOutputURL: URL?
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
    private var cursorSamplingStartUptime: TimeInterval?
    private var cursorPausedDuration: TimeInterval = 0
    private var cursorPauseStartedUptime: TimeInterval?
    private var cursorSamplingGeneration: UInt64 = 0
    var onStateChange: (() -> Void)?

    private init() {
        controlBar.onStop = { [weak self] in self?.stop() }
        controlBar.onTogglePause = { [weak self] in self?.togglePause() }
    }

    func toggle() { (isRecording || microphonePermissionTask != nil) ? stop() : start() }

    func togglePause() {
        guard isRecording, let engine else { return }
        isPaused.toggle()
        if isPaused {
            engine.pause()
            if cursorSamplingStartUptime != nil {
                cursorPauseStartedUptime = ProcessInfo.processInfo.systemUptime
                stopCursorSampling()
            }
        } else {
            if let pausedAt = cursorPauseStartedUptime {
                cursorPausedDuration += ProcessInfo.processInfo.systemUptime - pausedAt
                cursorPauseStartedUptime = nil
            }
            engine.resume()
            if cursorSamplingStartUptime != nil { startCursorSampling() }
        }
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
    func toggleGIF() { (isRecording || microphonePermissionTask != nil) ? stop() : startGIF() }

    private func beginRecording(displayID: CGDirectDisplayID, sourceRect: CGRect?, gif: Bool,
                                windowID: CGWindowID? = nil,
                                microphonePermission: Bool? = nil) {
        // Recording hotkeys bypass CaptureCoordinator's own entry guards. Refuse countdown,
        // freeze-frame, overlay-selection, and scrolling-capture phases so their delayed work can
        // never enter a concurrently running SCStream pipeline.
        guard finalizationTask == nil else {
            HUD.show("Finishing previous recording…")
            return
        }
        guard !isRecording, microphonePermissionTask == nil,
              !CaptureCoordinator.shared.isCaptureInProgress else { return }

        let wantsMicrophone = Preferences.recordMicrophone && !gif
        if wantsMicrophone, microphonePermission == nil,
           AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            let task = Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard let self else { return }
                self.microphonePermissionTask = nil
                guard !Task.isCancelled else { return }
                self.beginRecording(
                    displayID: displayID, sourceRect: sourceRect, gif: gif,
                    windowID: windowID, microphonePermission: granted)
            }
            microphonePermissionTask = task
            return
        }

        let microphoneAuthorized = microphonePermission
            ?? (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        savesToDisk = Preferences.afterCaptureActions(for: .recording).contains(.save)
        let url = Self.recordingURL(ext: gif ? "gif" : "mp4", toSaveDirectory: savesToDisk)
        let sessionID = UUID()
        activeSessionID = sessionID
        activeOutputURL = url
        if !gif { Preferences.recordingInProgressPath = url.path } // for crash recovery
        let engine = RecordingEngine { failedEngine, error in
            Task { @MainActor in
                RecordingController.shared.handleUnexpectedStop(from: failedEngine, error: error)
            }
        }
        engine.captureSystemAudio = Preferences.recordSystemAudio
        engine.captureMicrophone = wantsMicrophone && microphoneAuthorized
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
        resetCursorTimeline()
        if sourceRect == nil, windowID == nil, !gif,
           let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            cursorDisplayFrame = screen.frame
            cursorSamplingStartUptime = ProcessInfo.processInfo.systemUptime
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
            do {
                try Task<Never, Never>.checkCancellation()
                if let windowID {
                    try await engine.start(windowID: windowID, to: url)
                } else {
                    try await engine.start(displayID: displayID, sourceRect: sourceRect, to: url)
                }
                if Self.sessionStillOwnsState(sessionID, activeSessionID: activeSessionID,
                                              engineMatches: self.engine === engine) {
                    startTask = nil
                }
            } catch {
                // A may fail after the user stopped it and already started B. Never let A tear down
                // B's engine, overlays, timer, UI state, or crash-recovery path.
                guard Self.sessionStillOwnsState(sessionID, activeSessionID: activeSessionID,
                                                 engineMatches: self.engine === engine) else { return }
                let wasCancelled = error is CancellationError || Task.isCancelled
                tearDownRecordingUI()
                cursorSamples.removeAll(keepingCapacity: false)
                cursorDisplayFrame = .zero
                resetCursorTimeline()
                if Self.recoveryPathBelongs(to: url, currentPath: Preferences.recordingInProgressPath) {
                    Preferences.recordingInProgressPath = nil
                }
                activeSessionID = nil
                activeOutputURL = nil
                startTask = nil
                self.engine = nil
                onStateChange?()
                if !wasCancelled { showError(error) }
            }
        }
    }

    func stop() {
        if let microphonePermissionTask {
            // requestAccess itself will finish only when TCC answers. Cancellation prevents its
            // continuation from constructing a session; retaining the handle blocks duplicate
            // prompts/tasks until that answer arrives.
            microphonePermissionTask.cancel()
            return
        }
        guard isRecording, let engine else { return }
        let outputURL = activeOutputURL
        activeSessionID = nil
        activeOutputURL = nil
        tearDownRecordingUI()
        self.engine = nil
        onStateChange?()

        let startTask = self.startTask
        self.startTask = nil
        startTask?.cancel()
        let track = cursorSamples.isEmpty ? nil : CursorTrack(samples: cursorSamples)
        cursorSamples.removeAll(keepingCapacity: false)
        cursorDisplayFrame = .zero
        resetCursorTimeline()
        let saved = savesToDisk
        finalizationGeneration &+= 1
        let retiringGeneration = finalizationGeneration
        finalizationTask = Task { [weak self] in
            defer {
                if let self, self.finalizationGeneration == retiringGeneration {
                    self.finalizationTask = nil
                }
            }
            // Ensure start() (and its startCapture) finished before stopping, so the SCStream
            // is actually torn down and never leaks.
            await startTask?.value
            let url = await engine.stop()
            // A's finalization may complete after B has already installed its recovery path.
            if let outputURL,
               Self.recoveryPathBelongs(to: outputURL, currentPath: Preferences.recordingInProgressPath) {
                Preferences.recordingInProgressPath = nil
            }
            guard let url else { return }
            // Keep the one-session finalization gate until sidecar encoding and the potentially
            // large history copy finish. This prevents short repeated recordings from piling up
            // detached tasks blocked on the archive lock.
            await Task.detached(priority: .utility) {
                track?.write(for: url)
                CaptureHistoryStore.add(fileURL: url)
            }.value

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

    private func handleUnexpectedStop(from failedEngine: RecordingEngine, error: Error) {
        guard isRecording, engine === failedEngine else { return }
        HUD.show("Recording stopped: \(error.localizedDescription)")
        // Use the regular path so the partial movie is finalized when possible and every overlay,
        // event monitor, timer, camera/mic session, and crash-recovery marker is released.
        stop()
    }

    private func tearDownRecordingUI() {
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
    }

    /// Pure identity gates used by every delayed start/error/finalization callback. Kept
    /// nonisolated so the A-stop/B-start race can be covered without constructing AppKit UI.
    nonisolated static func sessionStillOwnsState(_ expected: UUID, activeSessionID: UUID?,
                                                  engineMatches: Bool) -> Bool {
        engineMatches && activeSessionID == expected
    }

    nonisolated static func recoveryPathBelongs(to outputURL: URL, currentPath: String?) -> Bool {
        currentPath == outputURL.path
    }

    /// Hard backstop: 25 Hz × 1 h ≈ 90k samples ≈ 2 MB of structs. With stationary-run dedupe
    /// below this is effectively unreachable in real recordings.
    private static let maxCursorSamples = 90_000

    private func startCursorSampling() {
        guard cursorTimer == nil else { return }
        guard let sessionID = activeSessionID else { return }
        let start = cursorSamplingStartUptime ?? ProcessInfo.processInfo.systemUptime
        cursorSamplingStartUptime = start
        cursorSamplingGeneration &+= 1
        let generation = cursorSamplingGeneration
        let timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.isRecording,
                      self.activeSessionID == sessionID,
                      self.cursorSamplingGeneration == generation,
                      self.cursorDisplayFrame.width > 0 else { return }
                guard self.cursorSamples.count < Self.maxCursorSamples else {
                    self.stopCursorSampling()
                    return
                }
                let m = NSEvent.mouseLocation
                let f = self.cursorDisplayFrame
                let x = min(max(0, (m.x - f.minX) / f.width), 1)
                let y = min(max(0, (m.y - f.minY) / f.height), 1)
                let elapsed = Self.cursorTimelineTime(
                    now: ProcessInfo.processInfo.systemUptime,
                    start: start,
                    pausedDuration: self.cursorPausedDuration)
                let sample = CursorSample(t: elapsed, x: Double(x), y: Double(y))
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

    private func stopCursorSampling() {
        cursorSamplingGeneration &+= 1
        cursorTimer?.invalidate()
        cursorTimer = nil
    }

    private func resetCursorTimeline() {
        cursorSamplingGeneration &+= 1
        cursorSamplingStartUptime = nil
        cursorPausedDuration = 0
        cursorPauseStartedUptime = nil
    }

    nonisolated static func cursorTimelineTime(
        now: TimeInterval, start: TimeInterval, pausedDuration: TimeInterval
    ) -> TimeInterval {
        max(0, now - start - pausedDuration)
    }

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
