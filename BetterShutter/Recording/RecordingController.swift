import AppKit

/// Starts/stops a screen recording and shows the floating control bar. Records the display under
/// the cursor to an MP4 in the save directory.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    private var engine: RecordingEngine?
    private var startTask: Task<Void, Never>?
    private let controlBar = RecordingControlBar()
    private(set) var isRecording = false
    private(set) var startDate: Date?
    var onStateChange: (() -> Void)?

    private init() {
        controlBar.onStop = { [weak self] in self?.stop() }
    }

    func toggle() { isRecording ? stop() : start() }

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
        let engine = RecordingEngine()
        engine.captureSystemAudio = Preferences.recordSystemAudio
        engine.showsCursor = Preferences.showCursorInRecording
        engine.fps = Preferences.recordingFPS
        engine.gifMode = gif
        self.engine = engine
        isRecording = true
        startDate = Date()
        controlBar.show()
        if Preferences.highlightClicks { ClickHighlighter.shared.start(displayID: displayID) }
        onStateChange?()

        startTask = Task {
            do {
                try await engine.start(displayID: displayID, sourceRect: sourceRect, to: url)
            } catch {
                isRecording = false
                controlBar.hide()
                ClickHighlighter.shared.stop()
                self.engine = nil
                onStateChange?()
                showError(error)
            }
        }
    }

    func stop() {
        guard isRecording, let engine else { return }
        isRecording = false
        startDate = nil
        controlBar.hide()
        ClickHighlighter.shared.stop()
        self.engine = nil
        onStateChange?()

        let startTask = self.startTask
        self.startTask = nil
        Task {
            // Ensure start() (and its startCapture) finished before stopping, so the SCStream
            // is actually torn down and never leaks.
            await startTask?.value
            let url = await engine.stop()
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
