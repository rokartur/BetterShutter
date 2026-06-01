import Cocoa
import BetterSettings
import BetterUpdater

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrapUpdater()
        setupStatusItem()
    }

    // MARK: - Updater

    private func bootstrapUpdater() {
        // TODO: replace pinnedPublicKeyBase64 with this app's own key
        //       (`betterupdater keygen`) and flip manifestRequired to true
        //       once signed release manifests are published.
        BetterUpdater.bootstrap(configuration: .init(
            owner: "rokartur",
            repo: "BetterShutter",
            displayName: "BetterShutter",
            bundleIdentifier: "app.bettershutter.BetterShutter",
            pinnedPublicKeyBase64: "duIBPTDie9dBTKqijWVxsVHZ89AMuorAz04gF6K+TUQ=",
            expectedTeamIdentifier: "N529W98U62",
            userAgentProduct: "BetterShutter-Updater",
            manifestRequired: false
        ))
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera",
            accessibilityDescription: "BetterShutter"
        )
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

        let updates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updates.target = self
        menu.addItem(updates)

        menu.addItem(.separator())

        let about = NSMenuItem(
            title: "About BetterShutter",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

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

    @objc private func checkForUpdates() {
        UpdateWindowPresenter.shared.show()
        Task {
            guard AppTranslocation.guardLaunchLocation() else { return }
            await BetterUpdater.shared.checkForUpdates(force: true)
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
