import Cocoa
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrapUpdater()
        HotKeyBridge.install()
        setupStatusItem()
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

        menu.addItem(.separator())

        let record = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self
        record.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
        menu.addItem(record)
        recordingItem = record

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
    @objc private func toggleRecording() { RecordingController.shared.toggle() }

    @objc private func openSettings() {
        let controller = settingsController ?? SettingsWindowController(
            configuration: makeSettingsConfiguration()
        )
        settingsController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.show()
    }
}
