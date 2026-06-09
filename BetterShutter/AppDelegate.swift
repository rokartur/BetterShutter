import Cocoa
import UniformTypeIdentifiers
import BetterSettings
import BetterShortcuts
import BetterUpdater

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Explicit entry point. Wires the delegate ourselves instead of relying on
    /// AppKit's synthesized @main + NSApplicationMain, which does not reliably
    /// install the delegate under the Xcode debug-dylib launcher (so
    /// applicationDidFinishLaunching never fired and no status item appeared).
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar agent: no Dock icon, no main window.
        app.setActivationPolicy(.accessory)
        app.run()
        // Keep the delegate alive for the (non-returning) run loop.
        withExtendedLifetime(delegate) {}
    }

    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?
    private var captureMenuItems: [(item: NSMenuItem, name: BetterShortcuts.Name)] = []
    private var recordingItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var recordingTimer: Timer?
    private var trimController: VideoTrimWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.runIfRequested() { return }
        bootstrapUpdater()
        HotKeyBridge.install()
        setupStatusItem()
        RecordingController.shared.onStateChange = { [weak self] in self?.recordingStateChanged() }
        OnboardingWindowController.showIfNeeded()
        recoverInterruptedRecording()
    }

    /// If a recording was in progress when the app last quit/crashed, its fragmented MP4 is still
    /// playable — surface it instead of silently losing the footage.
    private func recoverInterruptedRecording() {
        guard let path = Preferences.recordingInProgressPath else { return }
        Preferences.recordingInProgressPath = nil
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 0 else { return }
        HUD.show("Recovered interrupted recording")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Menubar recording timer

    private func recordingStateChanged() {
        if RecordingController.shared.isRecording {
            if recordingTimer == nil {
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateRecordingTitle() }
                }
                updateRecordingTitle()
            }
        } else {
            recordingTimer?.invalidate()
            recordingTimer = nil
            if let button = statusItem?.button {
                button.title = ""
                button.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "BetterShutter")
            }
        }
    }

    private func updateRecordingTitle() {
        guard let start = RecordingController.shared.startDate, let button = statusItem?.button else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recording")
        button.title = String(format: " %d:%02d", elapsed / 60, elapsed % 60)
    }

    /// Incoming `bettershutter://` automation URLs (once the scheme is registered for the target).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = URLCommand.parse(url) else { continue }
            dispatch(command)
        }
    }

    private func dispatch(_ command: URLCommand) {
        switch command {
        case .captureRegion:        CaptureCoordinator.shared.capture(.region)
        case .captureWindow:        CaptureCoordinator.shared.capture(.window)
        case .captureFullScreen:    CaptureCoordinator.shared.capture(.fullDisplay)
        case .captureText:          CaptureCoordinator.shared.captureText()
        case .captureScrolling:     CaptureCoordinator.shared.captureScrolling()
        case .captureCutout:        CaptureCoordinator.shared.captureCutout()
        case .record:               RecordingController.shared.toggle()
        case .recordGIF:            RecordingController.shared.toggleGIF()
        case .recordRegion:         CaptureCoordinator.shared.recordRegion()
        case .capturePreviousArea:  CaptureCoordinator.shared.captureLastRegion()
        case .openBrowser:          CaptureHistoryPanel.shared.show()
        case .openSettings:         openSettings()
        case .pinLast:              pinLastCapture()
        case .unknown(let raw):     HUD.show("Unknown command: \(raw)")
        }
    }

    // MARK: - Updater

    private func bootstrapUpdater() {
        // Security: release builds verify fail-closed (manifestRequired: true) so a
        // missing/invalid signed manifest refuses the update. Only DEBUG relaxes this
        // for local testing before the signing infrastructure exists.
        //
        // TODO before shipping a release: replace pinnedPublicKeyBase64 with this app's
        //      own key (`betterupdater keygen`) and publish signed release manifests.
        //      The placeholder key below cannot verify our releases, so with
        //      manifestRequired: true the release updater correctly installs nothing.
        #if DEBUG
        let manifestRequired = false
        #else
        let manifestRequired = true
        #endif

        BetterUpdater.bootstrap(configuration: .init(
            owner: "rokartur",
            repo: "BetterShutter",
            displayName: "BetterShutter",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "app.bettershutter.BetterShutter",
            pinnedPublicKeyBase64: "duIBPTDie9dBTKqijWVxsVHZ89AMuorAz04gF6K+TUQ=",
            expectedTeamIdentifier: "N529W98U62",
            userAgentProduct: "BetterShutter-Updater",
            manifestRequired: manifestRequired
        ))
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "camera.fill",
                accessibilityDescription: "BetterShutter"
            )
            // Fallback so the item is never a zero-width (invisible) button.
            if button.image == nil { button.title = "BetterShutter" }
        }
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        captureMenuItems.removeAll()
        addCaptureItem(to: menu, title: "Quick Screenshot", symbol: "bolt",
                       action: #selector(quickScreenshot), name: .quickScreenshot)
        addCaptureItem(to: menu, title: "Screenshot & Markup", symbol: "pencil.and.outline",
                       action: #selector(screenshotEdit), name: .screenshotEdit)
        addCaptureItem(to: menu, title: "Capture Region", symbol: "rectangle.dashed",
                       action: #selector(captureRegion), name: .captureRegion)
        addCaptureItem(to: menu, title: "Capture Window", symbol: "macwindow",
                       action: #selector(captureWindow), name: .captureWindow)
        addCaptureItem(to: menu, title: "Capture Full Screen", symbol: "rectangle.inset.filled",
                       action: #selector(captureFullScreen), name: .captureFullScreen)
        addCaptureItem(to: menu, title: "Capture Text", symbol: "text.viewfinder",
                       action: #selector(captureText), name: .captureText)
        addCaptureItem(to: menu, title: "Capture Object", symbol: "person.and.background.dotted",
                       action: #selector(captureCutout), name: .captureCutout)
        addCaptureItem(to: menu, title: "Scrolling Capture", symbol: "arrow.up.and.down.text.horizontal",
                       action: #selector(captureScrolling), name: .captureScrolling)

        let previous = NSMenuItem(title: "Capture Previous Area",
                                  action: #selector(capturePreviousArea), keyEquivalent: "")
        previous.target = self
        previous.image = NSImage(systemSymbolName: "arrow.counterclockwise.circle", accessibilityDescription: "Previous Area")
        menu.addItem(previous)

        menu.addItem(.separator())

        let record = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self
        record.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
        menu.addItem(record)
        recordingItem = record

        let pause = NSMenuItem(title: "Pause Recording", action: #selector(togglePauseRecording), keyEquivalent: "")
        pause.target = self
        pause.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Pause")
        pause.isHidden = true
        menu.addItem(pause)
        pauseItem = pause

        addCaptureItem(to: menu, title: "Record Region", symbol: "rectangle.dashed",
                       action: #selector(recordRegion), name: .recordRegion)
        addCaptureItem(to: menu, title: "Record GIF", symbol: "square.stack.3d.forward.dottedline",
                       action: #selector(recordGIF), name: .recordGIF)

        menu.addItem(.separator())

        let history = NSMenuItem(title: "Capture History", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        history.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Capture History")
        menu.addItem(history)

        menu.addItem(.separator())

        let editClipboard = NSMenuItem(title: "Edit Image from Clipboard",
                                       action: #selector(editFromClipboard), keyEquivalent: "")
        editClipboard.target = self
        editClipboard.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipboard")
        menu.addItem(editClipboard)

        let editFile = NSMenuItem(title: "Edit Image…", action: #selector(openImageForEditing), keyEquivalent: "")
        editFile.target = self
        editFile.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: "Edit Image")
        menu.addItem(editFile)

        let trim = NSMenuItem(title: "Trim Video…", action: #selector(trimVideo), keyEquivalent: "")
        trim.target = self
        trim.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Trim Video")
        menu.addItem(trim)

        let openProj = NSMenuItem(title: "Open Project…", action: #selector(openProject), keyEquivalent: "")
        openProj.target = self
        openProj.image = NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: "Open Project")
        menu.addItem(openProj)

        menu.addItem(.separator())

        let pinLast = NSMenuItem(title: "Pin Last Capture", action: #selector(pinLastCapture), keyEquivalent: "")
        pinLast.target = self
        pinLast.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")
        menu.addItem(pinLast)

        let closePins = NSMenuItem(title: "Close All Pins", action: #selector(closeAllPins), keyEquivalent: "")
        closePins.target = self
        closePins.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: "Close Pins")
        menu.addItem(closePins)

        let reopen = NSMenuItem(title: "Reopen Last Capture", action: #selector(reopenLast), keyEquivalent: "")
        reopen.target = self
        reopen.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Reopen")
        menu.addItem(reopen)

        let restoreClosed = NSMenuItem(title: "Restore Closed Quick Access", action: #selector(restoreClosed), keyEquivalent: "")
        restoreClosed.target = self
        restoreClosed.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Restore")
        menu.addItem(restoreClosed)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Quit BetterShutter",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        return menu
    }

    private func addCaptureItem(
        to menu: NSMenu, title: String, symbol: String, action: Selector, name: BetterShortcuts.Name
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        menu.addItem(item)
        captureMenuItems.append((item, name))
    }

    /// Refresh the capture items' key equivalents from the live shortcuts each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for (item, name) in captureMenuItems {
            applyShortcut(name, to: item)
        }
        if let recordingItem {
            recordingItem.title = RecordingController.shared.isRecording ? "Stop Recording" : "Start Recording"
            applyShortcut(.toggleRecording, to: recordingItem)
        }
        if let pauseItem {
            pauseItem.isHidden = !RecordingController.shared.isRecording
            pauseItem.title = RecordingController.shared.isPaused ? "Resume Recording" : "Pause Recording"
        }
    }

    private func applyShortcut(_ name: BetterShortcuts.Name, to item: NSMenuItem) {
        if let ke = HotKeyBridge.menuKeyEquivalent(for: name) {
            item.keyEquivalent = ke.key
            item.keyEquivalentModifierMask = ke.modifiers
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    // MARK: - Actions

    @objc private func quickScreenshot() { CaptureCoordinator.shared.captureQuick() }
    @objc private func screenshotEdit() { CaptureCoordinator.shared.captureAndEdit() }
    @objc private func captureRegion() { CaptureCoordinator.shared.capture(.region) }
    @objc private func captureWindow() { CaptureCoordinator.shared.capture(.window) }
    @objc private func captureFullScreen() { CaptureCoordinator.shared.capture(.fullDisplay) }
    @objc private func captureText() { CaptureCoordinator.shared.captureText() }
    @objc private func captureCutout() { CaptureCoordinator.shared.captureCutout() }
    @objc private func captureScrolling() { CaptureCoordinator.shared.captureScrolling() }
    @objc private func capturePreviousArea() { CaptureCoordinator.shared.captureLastRegion() }
    @objc private func openHistory() { CaptureHistoryPanel.shared.toggle() }

    @objc private func editFromClipboard() {
        guard let image = NSImage(pasteboard: .general), let cg = Self.cgImage(from: image) else {
            HUD.show("No image in clipboard")
            return
        }
        CaptureCoordinator.shared.edit(CapturedImage(cgImage: cg, scale: 1, displayID: nil), mode: .region)
    }

    @objc private func openImageForEditing() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url), let cg = Self.cgImage(from: image) else { return }
        CaptureCoordinator.shared.edit(CapturedImage(cgImage: cg, scale: 1, displayID: nil), mode: .region)
    }

    @objc private func pinLastCapture() {
        guard let item = CaptureHistory.shared.items.first else { HUD.show("No recent capture"); return }
        PinController.shared.pin(item.image)
    }

    @objc private func closeAllPins() { PinController.shared.closeAll() }

    @objc private func reopenLast() {
        guard let item = CaptureHistory.shared.items.first else { HUD.show("No recent capture"); return }
        CaptureCoordinator.shared.reopenPreview(item)
    }

    @objc private func restoreClosed() { CaptureCoordinator.shared.restoreClosedPreview() }

    @objc private func trimVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let controller = VideoTrimWindowController(url: url)
        trimController = controller
        controller.show()
    }

    @objc private func openProject() {
        let panel = NSOpenPanel()
        if let type = UTType(filenameExtension: AnnotationProjectIO.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let project = try? AnnotationProjectIO.read(url),
              let base = AnnotationProjectIO.baseImage(project) else { return }
        CaptureCoordinator.shared.editProject(
            CapturedImage(cgImage: base, scale: 1, displayID: nil),
            elements: AnnotationProjectIO.elements(project)
        )
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    @objc private func toggleRecording() { RecordingController.shared.toggle() }
    @objc private func togglePauseRecording() { RecordingController.shared.togglePause() }
    @objc private func recordRegion() { CaptureCoordinator.shared.recordRegion() }
    @objc private func recordGIF() { RecordingController.shared.toggleGIF() }

    @objc private func openSettings() {
        let controller = settingsController ?? SettingsWindowController(
            configuration: makeSettingsConfiguration()
        )
        settingsController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.show()
    }
}
