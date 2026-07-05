import AppKit

/// The camera-shutter feedback for a capture. `NSSound(named: "Grab")` looks only in
/// `/System/Library/Sounds` and the app bundle — the screenshot sounds live under the
/// CoreAudio component instead, so name lookup silently returns nil and nothing plays.
/// Load the real file by path and cache the decoded `NSSound`.
@MainActor
enum CaptureSound {
    private static let systemSoundsDir =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system"

    /// Candidates in priority order: the modern screenshot sound, the classic Grab sound, then a
    /// bundled `/System/Library/Sounds` fallback that `NSSound(named:)` can always resolve.
    private static let sound: NSSound? = {
        for name in ["Screen Capture", "Grab"] {
            let path = "\(systemSoundsDir)/\(name).aif"
            if let s = NSSound(contentsOfFile: path, byReference: true) { return s }
        }
        return NSSound(named: "Tink")
    }()

    /// Play the shutter sound if the user enabled it. No-op otherwise.
    static func play() {
        guard Preferences.captureSoundEnabled, let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
