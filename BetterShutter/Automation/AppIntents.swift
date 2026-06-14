import AppIntents

/// macOS Shortcuts.app integration via App Intents — every capture/recording action exposed as a
/// Shortcut so users can script BetterShutter (parity with the URL scheme, but native to Shortcuts).
/// Each intent just dispatches to the shared CaptureCoordinator / RecordingController on the main actor.

@available(macOS 13.0, *)
private func runOnMain(_ body: @MainActor @escaping () -> Void) async {
    await MainActor.run { body() }
}

@available(macOS 13.0, *)
struct CaptureRegionIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Region"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await runOnMain { CaptureCoordinator.shared.capture(.region) }
        return .result()
    }
}

@available(macOS 13.0, *)
struct CaptureWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Window"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await runOnMain { CaptureCoordinator.shared.capture(.window) }
        return .result()
    }
}

@available(macOS 13.0, *)
struct CaptureFullScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Full Screen"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await runOnMain { CaptureCoordinator.shared.capture(.fullDisplay) }
        return .result()
    }
}

@available(macOS 13.0, *)
struct AllInOneCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "All-in-One Capture"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await runOnMain { CaptureCoordinator.shared.captureAllInOne() }
        return .result()
    }
}

@available(macOS 13.0, *)
struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Text (OCR)"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await runOnMain { CaptureCoordinator.shared.captureText() }
        return .result()
    }
}

@available(macOS 13.0, *)
struct CaptureObjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Object (Cutout)"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await runOnMain { CaptureCoordinator.shared.captureCutout() }
        return .result()
    }
}

@available(macOS 13.0, *)
struct ScrollingCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Scrolling Capture"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await runOnMain { CaptureCoordinator.shared.captureScrolling() }
        return .result()
    }
}

@available(macOS 13.0, *)
struct CapturePreviousAreaIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Previous Area"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await runOnMain { CaptureCoordinator.shared.captureLastRegion() }
        return .result()
    }
}

@available(macOS 13.0, *)
struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start or Stop Recording"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await runOnMain { RecordingController.shared.toggle() }
        return .result()
    }
}

@available(macOS 13.0, *)
struct RecordGIFIntent: AppIntent {
    static let title: LocalizedStringResource = "Record GIF"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await runOnMain { RecordingController.shared.toggleGIF() }
        return .result()
    }
}

@available(macOS 13.0, *)
struct PinLastCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin Last Capture"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await runOnMain {
            if let item = CaptureHistory.shared.items.first { PinController.shared.pin(item.image) }
        }
        return .result()
    }
}

@available(macOS 13.0, *)
struct BetterShutterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AllInOneCaptureIntent(),
                    phrases: ["Capture with \(.applicationName)"],
                    shortTitle: "All-in-One Capture", systemImageName: "square.dashed.inset.filled")
        AppShortcut(intent: CaptureRegionIntent(),
                    phrases: ["Capture a region with \(.applicationName)"],
                    shortTitle: "Capture Region", systemImageName: "rectangle.dashed")
        AppShortcut(intent: CaptureFullScreenIntent(),
                    phrases: ["Capture the screen with \(.applicationName)"],
                    shortTitle: "Capture Full Screen", systemImageName: "rectangle.inset.filled")
        AppShortcut(intent: CaptureTextIntent(),
                    phrases: ["Capture text with \(.applicationName)"],
                    shortTitle: "Capture Text", systemImageName: "text.viewfinder")
        AppShortcut(intent: ToggleRecordingIntent(),
                    phrases: ["Start recording with \(.applicationName)"],
                    shortTitle: "Start or Stop Recording", systemImageName: "record.circle")
    }
}
