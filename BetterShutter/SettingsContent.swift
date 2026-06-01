import AppKit
import BetterSettings
import BetterShortcuts
import BetterUpdater
import ServiceManagement

/// Builds the BetterSettings window configuration for BetterShutter.
@MainActor
func makeSettingsConfiguration() -> SettingsConfiguration {
    SettingsConfiguration(
        tabs: [
            SettingsTab(id: "general", title: "General", icon: "gearshape.fill", iconStyle: .neutral),
            SettingsTab(id: "shortcuts", title: "Shortcuts", icon: "command",
                        iconStyle: .solid(SettingsColor(hex: 0x5E5CE6))),
            SettingsTab(id: "capture", title: "Capture", icon: "camera.viewfinder",
                        iconStyle: .solid(SettingsColor(hex: 0x0A84FF))),
            SettingsTab(id: "output", title: "Output", icon: "square.and.arrow.down",
                        iconStyle: .solid(SettingsColor(hex: 0x30D158))),
            SettingsTab(id: "about", title: "About", icon: "info.circle.fill",
                        iconStyle: .solid(SettingsColor(hex: 0xFF6F00))),
        ],
        searchItems: [
            SettingsSearchItem(id: "general.launchAtLogin", tabID: "general", sectionAnchor: "general.behavior",
                               title: "Launch at login", tabTitle: "General", sectionTitle: "Behavior",
                               keywords: ["startup", "boot", "open at login"]),
            SettingsSearchItem(id: "general.autoUpdate", tabID: "general", sectionAnchor: "general.updates",
                               title: "Check for updates automatically", tabTitle: "General", sectionTitle: "Updates",
                               keywords: ["update", "upgrade", "auto"]),
            SettingsSearchItem(id: "shortcuts.region", tabID: "shortcuts", sectionAnchor: "shortcuts.capture",
                               title: "Capture Region shortcut", tabTitle: "Shortcuts", sectionTitle: "Capture",
                               keywords: ["hotkey", "shortcut", "region", "selection"]),
            SettingsSearchItem(id: "output.location", tabID: "output", sectionAnchor: "output.files",
                               title: "Save location", tabTitle: "Output", sectionTitle: "Files",
                               keywords: ["folder", "directory", "save", "location"]),
        ],
        contentProvider: { tab, _ in
            switch tab.id {
            case "general": return GeneralSettingsTab()
            case "shortcuts": return ShortcutsSettingsTab()
            case "capture": return CaptureSettingsTab()
            case "output": return OutputSettingsTab()
            default: return AboutSettingsTab()
            }
        }
    )
}

// MARK: - General

final class GeneralSettingsTab: SettingsTabViewController {
    private let updater = BetterUpdater.shared

    override func setupContent() {
        let behavior = addSection(title: "Behavior", anchor: "general.behavior")
        let loginSwitch = NSSwitch()
        loginSwitch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLaunchAtLogin(_:))
        addRow(to: behavior, title: "Launch at login",
               subtitle: "Start automatically when you log in.",
               accessory: loginSwitch, searchItemID: "general.launchAtLogin")

        let updates = addSection(title: "Updates", anchor: "general.updates")
        let autoSwitch = NSSwitch()
        autoSwitch.state = updater.automaticInstallEnabled ? .on : .off
        autoSwitch.target = self
        autoSwitch.action = #selector(toggleAutoUpdate(_:))
        addRow(to: updates, title: "Check for updates automatically",
               subtitle: "Download and install updates in the background.",
               accessory: autoSwitch, searchItemID: "general.autoUpdate")

        let checkButton = NSButton(title: "Check Now", target: self, action: #selector(checkForUpdates))
        checkButton.bezelStyle = .rounded
        addRow(to: updates, title: "Check for updates",
               subtitle: "Look for a new version right now.", accessory: checkButton)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    @objc private func toggleAutoUpdate(_ sender: NSSwitch) {
        updater.automaticInstallEnabled = (sender.state == .on)
    }

    @objc private func checkForUpdates() {
        Task { await updater.checkForUpdates(force: true) }
    }
}

// MARK: - Shortcuts

final class ShortcutsSettingsTab: SettingsTabViewController {
    override func setupContent() {
        let section = addSection(title: "Capture", anchor: "shortcuts.capture")
        addRecorder(to: section, title: "Capture Region",
                    subtitle: "Drag out a selection to capture.", name: .captureRegion,
                    searchItemID: "shortcuts.region")
        addRecorder(to: section, title: "Capture Window",
                    subtitle: "Click a window to capture it.", name: .captureWindow,
                    searchItemID: nil)
        addRecorder(to: section, title: "Capture Full Screen",
                    subtitle: "Capture the display under the cursor.", name: .captureFullScreen,
                    searchItemID: nil)
        addRecorder(to: section, title: "Capture Text (OCR)",
                    subtitle: "Select a region and copy its text.", name: .captureText,
                    searchItemID: nil)

        let recording = addSection(title: "Recording", anchor: "shortcuts.recording")
        addRecorder(to: recording, title: "Start / Stop Recording",
                    subtitle: "Record the display to an MP4.", name: .toggleRecording,
                    searchItemID: nil)
        addRecorder(to: recording, title: "Record Region",
                    subtitle: "Select an area and record just that.", name: .recordRegion,
                    searchItemID: nil)
        addRecorder(to: recording, title: "Record GIF",
                    subtitle: "Record the display to an animated GIF.", name: .recordGIF,
                    searchItemID: nil)
    }

    private func addRecorder(
        to section: SettingsSectionView, title: String, subtitle: String,
        name: BetterShortcuts.Name, searchItemID: String?
    ) {
        let recorder = BetterShortcuts.RecorderCocoa(for: name)
        recorder.widthAnchor.constraint(equalToConstant: 170).isActive = true
        addRow(to: section, title: title, subtitle: subtitle, accessory: recorder, searchItemID: searchItemID)
    }
}

// MARK: - Capture

final class CaptureSettingsTab: SettingsTabViewController {
    override func setupContent() {
        let behavior = addSection(title: "After Capture", anchor: "capture.after")
        let popup = NSPopUpButton()
        for action in AfterCaptureAction.allCases { popup.addItem(withTitle: action.presentableName) }
        popup.selectItem(withTitle: Preferences.afterCaptureAction.presentableName)
        popup.target = self
        popup.action = #selector(changeAfterAction(_:))
        addRow(to: behavior, title: "When a capture is taken",
               subtitle: "Copy to the clipboard and/or show the floating preview.", accessory: popup)

        let downscale = NSSwitch()
        downscale.state = Preferences.downscaleRetina ? .on : .off
        downscale.target = self
        downscale.action = #selector(toggleDownscale(_:))
        addRow(to: behavior, title: "Downscale Retina to 1×",
               subtitle: "Halve the pixel size of Retina captures for smaller files.", accessory: downscale)

        let overlay = addSection(title: "Overlay", anchor: "capture.overlay")
        let magnifier = NSSwitch()
        magnifier.state = Preferences.magnifierEnabled ? .on : .off
        magnifier.target = self
        magnifier.action = #selector(toggleMagnifier(_:))
        addRow(to: overlay, title: "Show magnifier loupe",
               subtitle: "Pixel-accurate zoom with a color readout while selecting.", accessory: magnifier)

        let sound = NSSwitch()
        sound.state = Preferences.captureSoundEnabled ? .on : .off
        sound.target = self
        sound.action = #selector(toggleSound(_:))
        addRow(to: overlay, title: "Play capture sound", subtitle: "A shutter sound on capture.", accessory: sound)

        let recording = addSection(title: "Recording", anchor: "capture.recording")
        let audio = NSSwitch()
        audio.state = Preferences.recordSystemAudio ? .on : .off
        audio.target = self
        audio.action = #selector(toggleRecordAudio(_:))
        addRow(to: recording, title: "Record system audio",
               subtitle: "Include computer audio in screen recordings.", accessory: audio)

        let clicks = NSSwitch()
        clicks.state = Preferences.highlightClicks ? .on : .off
        clicks.target = self
        clicks.action = #selector(toggleHighlightClicks(_:))
        addRow(to: recording, title: "Highlight mouse clicks",
               subtitle: "Show an animated ring at each click in recordings.", accessory: clicks)

        let cursor = NSSwitch()
        cursor.state = Preferences.showCursorInRecording ? .on : .off
        cursor.target = self
        cursor.action = #selector(toggleShowCursor(_:))
        addRow(to: recording, title: "Show cursor",
               subtitle: "Include the mouse pointer in recordings.", accessory: cursor)
    }

    @objc private func toggleRecordAudio(_ sender: NSSwitch) { Preferences.recordSystemAudio = (sender.state == .on) }
    @objc private func toggleHighlightClicks(_ sender: NSSwitch) { Preferences.highlightClicks = (sender.state == .on) }
    @objc private func toggleShowCursor(_ sender: NSSwitch) { Preferences.showCursorInRecording = (sender.state == .on) }
    @objc private func toggleDownscale(_ sender: NSSwitch) { Preferences.downscaleRetina = (sender.state == .on) }

    @objc private func changeAfterAction(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if AfterCaptureAction.allCases.indices.contains(index) {
            Preferences.afterCaptureAction = AfterCaptureAction.allCases[index]
        }
    }

    @objc private func toggleMagnifier(_ sender: NSSwitch) { Preferences.magnifierEnabled = (sender.state == .on) }
    @objc private func toggleSound(_ sender: NSSwitch) { Preferences.captureSoundEnabled = (sender.state == .on) }
}

// MARK: - Output

final class OutputSettingsTab: SettingsTabViewController {
    private let folderButton = NSButton(title: "", target: nil, action: nil)
    private let templateField = NSTextField()

    override func setupContent() {
        let files = addSection(title: "Files", anchor: "output.files")

        folderButton.bezelStyle = .rounded
        folderButton.title = Preferences.saveDirectory.lastPathComponent
        folderButton.target = self
        folderButton.action = #selector(chooseFolder)
        addRow(to: files, title: "Save location",
               subtitle: "Where screenshots are written.", accessory: folderButton,
               searchItemID: "output.location")

        let formatPopup = NSPopUpButton()
        for format in ImageFileFormat.allCases { formatPopup.addItem(withTitle: format.presentableName) }
        formatPopup.selectItem(withTitle: Preferences.format.presentableName)
        formatPopup.target = self
        formatPopup.action = #selector(changeFormat(_:))
        addRow(to: files, title: "Image format", subtitle: "PNG is lossless; JPEG is smaller.", accessory: formatPopup)

        templateField.stringValue = Preferences.filenameTemplate
        templateField.placeholderString = "Screenshot {date} at {time}"
        templateField.target = self
        templateField.action = #selector(changeTemplate(_:))
        templateField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        addRow(to: files, title: "Filename template",
               subtitle: "Tokens: {date} {time} {datetime} {n} {mode}.", accessory: templateField)
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Preferences.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            Preferences.saveDirectory = url
            folderButton.title = url.lastPathComponent
        }
    }

    @objc private func changeFormat(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if ImageFileFormat.allCases.indices.contains(index) {
            Preferences.format = ImageFileFormat.allCases[index]
        }
    }

    @objc private func changeTemplate(_ sender: NSTextField) {
        Preferences.filenameTemplate = sender.stringValue
    }
}

// MARK: - About

final class AboutSettingsTab: SettingsTabViewController {
    override func setupContent() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"

        let about = addSection(title: "About", anchor: "about.info")
        addRow(to: about, title: "BetterShutter", subtitle: "Version \(version) (\(build))")
    }
}
