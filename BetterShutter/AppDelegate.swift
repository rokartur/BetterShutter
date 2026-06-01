import Cocoa
import BetterSettings
import BetterUpdater

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrapUpdater()
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

    // MARK: - Actions

    @objc private func openSettings() {
        let controller = settingsController ?? SettingsWindowController(
            configuration: makeSettingsConfiguration()
        )
        settingsController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.show()
    }
}
