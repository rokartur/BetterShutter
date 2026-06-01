import AppKit

/// Starts/stops a screen recording and shows the floating control bar. Records the display under
/// the cursor to an MP4 in the save directory.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    private var engine: RecordingEngine?
    private let controlBar = RecordingControlBar()
    private(set) var isRecording = false
    var onStateChange: (() -> Void)?

    private init() {
        controlBar.onStop = { [weak self] in self?.stop() }
    }

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording, PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        let displayID = displayUnderMouse()
        let url = Self.recordingURL()
        let engine = RecordingEngine()
        engine.captureSystemAudio = Preferences.recordSystemAudio
        self.engine = engine
        isRecording = true
        controlBar.show()
        onStateChange?()

        Task {
            do {
                try await engine.start(displayID: displayID, to: url)
            } catch {
                isRecording = false
                controlBar.hide()
                self.engine = nil
                onStateChange?()
                showError(error)
            }
        }
    }

    func stop() {
        guard isRecording, let engine else { return }
        isRecording = false
        controlBar.hide()
        self.engine = nil
        onStateChange?()

        Task {
            let url = await engine.stop()
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    // MARK: Helpers

    private static func recordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dir = Preferences.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = formatter.string(from: Date())
        var url = dir.appendingPathComponent("Recording \(stamp).mp4")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("Recording \(stamp) (\(index)).mp4")
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
