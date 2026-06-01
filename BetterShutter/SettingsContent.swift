import AppKit
import BetterSettings

/// Builds the BetterSettings window configuration for BetterShutter.
@MainActor
func makeSettingsConfiguration() -> SettingsConfiguration {
    SettingsConfiguration(
        tabs: [
            SettingsTab(
                id: "general",
                title: "General",
                icon: "gearshape.fill",
                iconStyle: .neutral
            ),
            SettingsTab(
                id: "about",
                title: "About",
                icon: "info.circle.fill",
                iconStyle: .solid(SettingsColor(hex: 0xFF6F00))
            ),
        ],
        searchItems: [
            SettingsSearchItem(
                id: "general.launchAtLogin",
                tabID: "general",
                sectionAnchor: "general.behavior",
                title: "Launch at login",
                tabTitle: "General",
                sectionTitle: "Behavior",
                keywords: ["startup", "boot", "open at login"]
            ),
            SettingsSearchItem(
                id: "general.autoUpdate",
                tabID: "general",
                sectionAnchor: "general.updates",
                title: "Check for updates automatically",
                tabTitle: "General",
                sectionTitle: "Updates",
                keywords: ["update", "upgrade", "auto"]
            ),
        ],
        contentProvider: { tab, _ in
            switch tab.id {
            case "general": return GeneralSettingsTab()
            default: return AboutSettingsTab()
            }
        }
    )
}

final class GeneralSettingsTab: SettingsTabViewController {
    override func setupContent() {
        let behavior = addSection(title: "Behavior", anchor: "general.behavior")
        addRow(
            to: behavior,
            title: "Launch at login",
            subtitle: "Start automatically when you log in.",
            accessory: NSSwitch(),
            searchItemID: "general.launchAtLogin"
        )

        let updates = addSection(title: "Updates", anchor: "general.updates")
        addRow(
            to: updates,
            title: "Check for updates automatically",
            subtitle: "Download and install updates in the background.",
            accessory: NSSwitch(),
            searchItemID: "general.autoUpdate"
        )
    }
}

final class AboutSettingsTab: SettingsTabViewController {
    override func setupContent() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"

        let about = addSection(title: "About", anchor: "about.info")
        addRow(to: about, title: "BetterShutter", subtitle: "Version \(version) (\(build))")
    }
}
