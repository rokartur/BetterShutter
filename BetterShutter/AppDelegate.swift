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
    private var recentMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.runIfRequested() { return }
        bootstrapUpdater()
        HotKeyBridge.install()
        setupStatusItem()
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
        case .openBrowser:          CaptureBrowserWindowController.shared.show()
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

        let delay = NSMenuItem(title: "Capture After Delay", action: nil, keyEquivalent: "")
        delay.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Delay")
        let delaySub = NSMenu()
        for seconds in [3, 5, 10] {
            let it = NSMenuItem(title: "\(seconds) seconds", action: #selector(captureAfterDelay(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = seconds
            delaySub.addItem(it)
        }
        delay.submenu = delaySub
        menu.addItem(delay)

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

        addCaptureItem(to: menu, title: "Record Region", symbol: "rectangle.dashed",
                       action: #selector(recordRegion), name: .recordRegion)
        addCaptureItem(to: menu, title: "Record GIF", symbol: "square.stack.3d.forward.dottedline",
                       action: #selector(recordGIF), name: .recordGIF)

        menu.addItem(.separator())

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu()
        recent.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Recent")
        menu.addItem(recent)
        recentMenuItem = recent

        let browse = NSMenuItem(title: "Browse Captures…", action: #selector(openBrowser), keyEquivalent: "")
        browse.target = self
        browse.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Browse")
        menu.addItem(browse)

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
        rebuildRecentSubmenu()
    }

    private func rebuildRecentSubmenu() {
        guard let submenu = recentMenuItem?.submenu else { return }
        submenu.removeAllItems()
        let items = CaptureHistory.shared.items
        guard !items.isEmpty else {
            let empty = NSMenuItem(title: "No Recent Captures", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(
                title: "\(item.mode.fileTag) · \(formatter.string(from: item.date))",
                action: #selector(reopenRecent(_:)), keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = index
            menuItem.image = recentThumbnail(for: item.image)
            submenu.addItem(menuItem)
        }
        submenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear", action: #selector(clearRecent), keyEquivalent: "")
        clear.target = self
        submenu.addItem(clear)
    }

    private func recentThumbnail(for image: CapturedImage) -> NSImage {
        let height: CGFloat = 16
        let width = max(1, image.pixelSize.width / max(image.pixelSize.height, 1) * height)
        return NSImage(cgImage: image.cgImage, size: NSSize(width: width, height: height))
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

    @objc private func captureRegion() { CaptureCoordinator.shared.capture(.region) }
    @objc private func captureWindow() { CaptureCoordinator.shared.capture(.window) }
    @objc private func captureFullScreen() { CaptureCoordinator.shared.capture(.fullDisplay) }
    @objc private func captureText() { CaptureCoordinator.shared.captureText() }
    @objc private func captureCutout() { CaptureCoordinator.shared.captureCutout() }
    @objc private func captureScrolling() { CaptureCoordinator.shared.captureScrolling() }
    @objc private func captureAfterDelay(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        CaptureCoordinator.shared.captureFullScreenAfter(seconds)
    }
    @objc private func capturePreviousArea() { CaptureCoordinator.shared.captureLastRegion() }
    @objc private func openBrowser() { CaptureBrowserWindowController.shared.show() }

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
    @objc private func recordRegion() { CaptureCoordinator.shared.recordRegion() }
    @objc private func recordGIF() { RecordingController.shared.toggleGIF() }

    @objc private func reopenRecent(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              CaptureHistory.shared.items.indices.contains(index) else { return }
        CaptureCoordinator.shared.reopenPreview(CaptureHistory.shared.items[index])
    }

    @objc private func clearRecent() { CaptureHistory.shared.clear() }

    @objc private func openSettings() {
        let controller = settingsController ?? SettingsWindowController(
            configuration: makeSettingsConfiguration()
        )
        settingsController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.show()
    }
}
