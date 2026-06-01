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
            SettingsTab(id: "annotation", title: "Annotation", icon: "pencil.tip.crop.circle",
                        iconStyle: .solid(SettingsColor(hex: 0xFF375F))),
            SettingsTab(id: "beautify", title: "Beautify", icon: "wand.and.stars",
                        iconStyle: .solid(SettingsColor(hex: 0xBF5AF2))),
            SettingsTab(id: "output", title: "Output", icon: "square.and.arrow.down",
                        iconStyle: .solid(SettingsColor(hex: 0x30D158))),
            SettingsTab(id: "advanced", title: "Advanced", icon: "slider.horizontal.3",
                        iconStyle: .solid(SettingsColor(hex: 0x8E8E93))),
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
            case "annotation": return AnnotationSettingsTab()
            case "beautify": return BeautifySettingsTab()
            case "output": return OutputSettingsTab()
            case "advanced": return AdvancedSettingsTab()
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
        addRecorder(to: section, title: "Quick Screenshot",
                    subtitle: "Select an area; deliver it instantly (no action bar).", name: .quickScreenshot,
                    searchItemID: "shortcuts.quick")
        addRecorder(to: section, title: "Screenshot & Markup",
                    subtitle: "Select an area, then open the editor with every tool.", name: .screenshotEdit,
                    searchItemID: "shortcuts.markup")
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
        addRecorder(to: section, title: "Capture Object (Cutout)",
                    subtitle: "Lift the subject out as a transparent PNG.", name: .captureCutout,
                    searchItemID: nil)
        addRecorder(to: section, title: "Scrolling Capture",
                    subtitle: "Capture a long, scrolling region.", name: .captureScrolling,
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

        let tools = addSection(title: "Editor Tools", anchor: "shortcuts.tools")
        for (index, tool) in ToolKind.allCases.enumerated() {
            let field = NSTextField(string: String(tool.effectiveShortcutKey))
            field.alignment = .center
            field.tag = index
            field.target = self
            field.action = #selector(toolKeyChanged(_:))
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
            addRow(to: tools, title: tool.label, subtitle: "Single-key shortcut in the editor.", accessory: field)
        }
    }

    @objc private func toolKeyChanged(_ sender: NSTextField) {
        guard ToolKind.allCases.indices.contains(sender.tag) else { return }
        let tool = ToolKind.allCases[sender.tag]
        let key = sender.stringValue.lowercased().first
        Preferences.setEditorToolKey(key, for: tool)
        sender.stringValue = String(tool.effectiveShortcutKey)
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

        let shadow = NSSwitch()
        shadow.state = Preferences.includeWindowShadow ? .on : .off
        shadow.target = self
        shadow.action = #selector(toggleWindowShadow(_:))
        addRow(to: overlay, title: "Include window shadow",
               subtitle: "Keep the drop shadow when capturing a single window.", accessory: shadow)

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

        let mic = NSSwitch()
        mic.state = Preferences.recordMicrophone ? .on : .off
        mic.target = self
        mic.action = #selector(toggleRecordMic(_:))
        addRow(to: recording, title: "Record microphone",
               subtitle: "Add narration from the mic as a second audio track.", accessory: mic)

        let webcam = NSSwitch()
        webcam.state = Preferences.showWebcam ? .on : .off
        webcam.target = self
        webcam.action = #selector(toggleWebcam(_:))
        addRow(to: recording, title: "Webcam overlay",
               subtitle: "Float a round webcam bubble into the recording.", accessory: webcam)

        let keys = NSSwitch()
        keys.state = Preferences.showKeystrokes ? .on : .off
        keys.target = self
        keys.action = #selector(toggleKeystrokes(_:))
        addRow(to: recording, title: "Show keystrokes",
               subtitle: "Display pressed keys (needs Input Monitoring permission).", accessory: keys)

        let fps = NSPopUpButton()
        fps.addItems(withTitles: ["30 fps", "60 fps"])
        fps.selectItem(withTitle: Preferences.recordingFPS == 30 ? "30 fps" : "60 fps")
        fps.target = self
        fps.action = #selector(changeFPS(_:))
        addRow(to: recording, title: "Frame rate",
               subtitle: "Higher is smoother; lower makes smaller files.", accessory: fps)
    }

    @objc private func changeFPS(_ sender: NSPopUpButton) {
        Preferences.recordingFPS = sender.indexOfSelectedItem == 0 ? 30 : 60
    }

    @objc private func toggleRecordAudio(_ sender: NSSwitch) { Preferences.recordSystemAudio = (sender.state == .on) }
    @objc private func toggleRecordMic(_ sender: NSSwitch) { Preferences.recordMicrophone = (sender.state == .on) }
    @objc private func toggleWebcam(_ sender: NSSwitch) { Preferences.showWebcam = (sender.state == .on) }
    @objc private func toggleKeystrokes(_ sender: NSSwitch) { Preferences.showKeystrokes = (sender.state == .on) }
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
    @objc private func toggleWindowShadow(_ sender: NSSwitch) { Preferences.includeWindowShadow = (sender.state == .on) }
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

// MARK: - Annotation

final class AnnotationSettingsTab: SettingsTabViewController {
    override func setupContent() {
        let steps = addSection(title: "Step Badges", anchor: "annotation.steps")

        let format = NSPopUpButton()
        for f in StepFormat.allCases { format.addItem(withTitle: f.presentableName) }
        format.selectItem(at: StepFormat.allCases.firstIndex(of: Preferences.stepFormat) ?? 0)
        format.target = self
        format.action = #selector(changeStepFormat(_:))
        addRow(to: steps, title: "Number format",
               subtitle: "Numerals, letters, or Roman numerals for new step badges.", accessory: format)

        let start = NSTextField()
        start.integerValue = Preferences.stepStart
        start.alignment = .right
        start.target = self
        start.action = #selector(changeStepStart(_:))
        start.widthAnchor.constraint(equalToConstant: 56).isActive = true
        addRow(to: steps, title: "Start at", subtitle: "The first badge's number.", accessory: start)
    }

    @objc private func changeStepFormat(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if StepFormat.allCases.indices.contains(index) { Preferences.stepFormat = StepFormat.allCases[index] }
    }

    @objc private func changeStepStart(_ sender: NSTextField) {
        Preferences.stepStart = max(1, sender.integerValue)
        sender.integerValue = Preferences.stepStart
    }
}

// MARK: - Beautify

final class BeautifySettingsTab: SettingsTabViewController {
    private let presets = Preferences.beautifyPresets

    override func setupContent() {
        let section = addSection(title: "Auto-Apply", anchor: "beautify.auto")
        let popup = NSPopUpButton()
        popup.addItem(withTitle: "Off")
        for preset in presets { popup.addItem(withTitle: preset.name) }
        if let name = Preferences.autoBeautifyPresetName, let i = presets.firstIndex(where: { $0.name == name }) {
            popup.selectItem(at: i + 1)
        } else {
            popup.selectItem(at: 0)
        }
        popup.target = self
        popup.action = #selector(changeAutoPreset(_:))
        addRow(to: section, title: "Auto-apply preset",
               subtitle: "Style every capture with a saved preset; hold Shift while capturing to bypass.",
               accessory: popup)

        if presets.isEmpty {
            let note = addSection(title: "", anchor: "beautify.note")
            addRow(to: note, title: "No presets yet",
                   subtitle: "Open Beautify and use the bookmark menu ▸ Save Current Style to create one.",
                   accessory: NSView())
        }
    }

    @objc private func changeAutoPreset(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        Preferences.autoBeautifyPresetName = index <= 0 ? nil : presets[index - 1].name
    }
}

// MARK: - Advanced

final class AdvancedSettingsTab: SettingsTabViewController {
    override func setupContent() {
        let maintenance = addSection(title: "Maintenance", anchor: "advanced.maintenance")

        let clearColors = NSButton(title: "Clear", target: self, action: #selector(clearColors))
        clearColors.bezelStyle = .rounded
        addRow(to: maintenance, title: "Saved colors",
               subtitle: "Forget the editor's saved color palette.", accessory: clearColors)

        let reset = NSButton(title: "Reset…", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        addRow(to: maintenance, title: "Reset all settings",
               subtitle: "Restore every preference to its default.", accessory: reset)
    }

    @objc private func clearColors() {
        Preferences.recentColors = []
    }

    @objc private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "This restores every BetterShutter preference to its default. Saved files are not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
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
