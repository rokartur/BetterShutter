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

    func startGIF() {
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        beginRecording(displayID: displayUnderMouse(), sourceRect: nil, gif: true)
    }

    /// Stop if recording, otherwise start a GIF recording.
    func toggleGIF() { isRecording ? stop() : startGIF() }

    private func beginRecording(displayID: CGDirectDisplayID, sourceRect: CGRect?, gif: Bool) {
        guard !isRecording else { return }
        let url = Self.recordingURL(ext: gif ? "gif" : "mp4")
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
        // Keep our own control bar out of the recording (overlays stay in deliberately).
        engine.excludedWindowIDs = [controlBar.windowID].compactMap { $0 }
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
                try await engine.start(displayID: displayID, sourceRect: sourceRect, to: url)
            } catch {
                isRecording = false
                isPaused = false
                startDate = nil
                Preferences.recordingInProgressPath = nil
                controlBar.hide()
                ClickHighlighter.shared.stop()
                WebcamOverlay.shared.stop()
                KeystrokeOverlay.shared.stop()
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
        if iconsHidden { DesktopIconHider.shared.show(); iconsHidden = false }
        self.engine = nil
        onStateChange?()

        let startTask = self.startTask
        self.startTask = nil
        Task {
            // Ensure start() (and its startCapture) finished before stopping, so the SCStream
            // is actually torn down and never leaks.
            await startTask?.value
            let url = await engine.stop()
            Preferences.recordingInProgressPath = nil
            if let url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                Task.detached(priority: .utility) { CaptureHistoryStore.add(fileURL: url) }
            }
        }
    }

    // MARK: Helpers

    private static func recordingURL(ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dir = Preferences.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = formatter.string(from: Date())
        var url = dir.appendingPathComponent("Recording \(stamp).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("Recording \(stamp) (\(index)).\(ext)")
            index += 1
        }
        return url
    }

    private func displayUnderMouse() -> CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return screen?.displayID ?? CGMainDisplayID()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recording Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
