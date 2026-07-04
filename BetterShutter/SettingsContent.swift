import AppKit
import BetterSettings
import BetterShortcuts
import BetterUpdater
import ServiceManagement

/// Vertical-gradient sidebar badge in the macOS System Settings style,
/// `0xRRGGBB` from the top color to the bottom. `scale` nudges the SF Symbol
/// so optically small or busy glyphs read evenly against the rest.
private func tabIcon(_ top: UInt32, _ bottom: UInt32, scale: CGFloat = 1.0) -> SettingsTabIconStyle {
    SettingsTabIconStyle(
        gradientStart: SettingsColor(hex: top),
        gradientEnd: SettingsColor(hex: bottom),
        symbolScale: scale
    )
}

/// A compact on/off switch shared by every settings tab, so toggles stay one
/// size everywhere and sit lighter next to their labels.
@MainActor
private func makeToggle(_ isOn: Bool, target: AnyObject, action: Selector) -> NSSwitch {
    let toggle = NSSwitch()
    toggle.controlSize = .small
    toggle.state = isOn ? .on : .off
    toggle.target = target
    toggle.action = action
    return toggle
}

/// Builds the BetterSettings window configuration for BetterShutter.
@MainActor
func makeSettingsConfiguration() -> SettingsConfiguration {
    SettingsConfiguration(
        tabs: [
            SettingsTab(id: "general", title: "General", icon: "gearshape.fill",
                        iconStyle: tabIcon(0x9A9AA0, 0x6C6C70)),
            SettingsTab(id: "shortcuts", title: "Shortcuts", icon: "command",
                        iconStyle: tabIcon(0x7E7CF0, 0x5E5CE6, scale: 1.05)),
            SettingsTab(id: "capture", title: "Capture", icon: "camera.viewfinder",
                        iconStyle: tabIcon(0x3B9EFF, 0x0A84FF)),
            SettingsTab(id: "overlay", title: "Overlay", icon: "rectangle.dashed",
                        iconStyle: tabIcon(0x64D2FF, 0x2AA9E0, scale: 1.05)),
            SettingsTab(id: "recording", title: "Recording", icon: "video.fill",
                        iconStyle: tabIcon(0xFF6A61, 0xFF453A)),
            SettingsTab(id: "editor", title: "Editor", icon: "pencil.and.outline",
                        iconStyle: tabIcon(0xFF6482, 0xFF375F, scale: 1.05)),
            SettingsTab(id: "beautify", title: "Beautify", icon: "wand.and.stars",
                        iconStyle: tabIcon(0xCF6FF5, 0xBF5AF2, scale: 0.95)),
            SettingsTab(id: "output", title: "Output", icon: "square.and.arrow.down.fill",
                        iconStyle: tabIcon(0x34D65C, 0x28B84C)),
            SettingsTab(id: "cloud", title: "Cloud", icon: "icloud.and.arrow.up.fill",
                        iconStyle: tabIcon(0x66D4FF, 0x0A84FF)),
            SettingsTab(id: "advanced", title: "Advanced", icon: "wrench.and.screwdriver.fill",
                        iconStyle: tabIcon(0x7C7C82, 0x545458, scale: 0.95)),
            SettingsTab(id: "about", title: "About", icon: "info.circle.fill",
                        iconStyle: tabIcon(0xFFA230, 0xFF6F00)),
        ],
        searchItems: [
            SettingsSearchItem(id: "general.launchAtLogin", tabID: "general", sectionAnchor: "general.behavior",
                               title: "Launch at login", tabTitle: "General", sectionTitle: "Behavior",
                               keywords: ["startup", "boot", "open at login"]),
            SettingsSearchItem(id: "general.autoUpdate", tabID: "general", sectionAnchor: "general.updates",
                               title: "Check for updates automatically", tabTitle: "General", sectionTitle: "Updates",
                               keywords: ["update", "upgrade", "auto"]),
            SettingsSearchItem(id: "shortcuts.screenshot", tabID: "shortcuts", sectionAnchor: "shortcuts.capture",
                               title: "Capture Screenshot shortcut", tabTitle: "Shortcuts", sectionTitle: "Capture",
                               keywords: ["hotkey", "shortcut", "region", "window", "selection", "space"]),
            SettingsSearchItem(id: "overlay.magnifier", tabID: "overlay", sectionAnchor: "overlay.main",
                               title: "Show magnifier loupe", tabTitle: "Overlay", sectionTitle: "Selection",
                               keywords: ["zoom", "loupe", "pixel", "color"]),
            SettingsSearchItem(id: "recording.audio", tabID: "recording", sectionAnchor: "recording.audio",
                               title: "Record system audio", tabTitle: "Recording", sectionTitle: "Audio",
                               keywords: ["sound", "audio", "system", "record"]),
            SettingsSearchItem(id: "editor.tools", tabID: "editor", sectionAnchor: "editor.tools",
                               title: "Editor tool shortcuts", tabTitle: "Editor", sectionTitle: "Tool Shortcuts",
                               keywords: ["key", "tool", "shortcut", "single-key"]),
            SettingsSearchItem(id: "output.location", tabID: "output", sectionAnchor: "output.files",
                               title: "Save location", tabTitle: "Output", sectionTitle: "Files",
                               keywords: ["folder", "directory", "save", "location"]),
            SettingsSearchItem(id: "output.quality", tabID: "output", sectionAnchor: "output.files",
                               title: "Compression quality", tabTitle: "Output", sectionTitle: "Files",
                               keywords: ["jpeg", "quality", "compression", "heic", "webp"]),
        ],
        contentProvider: { tab, _ in
            switch tab.id {
            case "general": return GeneralSettingsTab()
            case "shortcuts": return ShortcutsSettingsTab()
            case "capture": return CaptureSettingsTab()
            case "overlay": return OverlaySettingsTab()
            case "recording": return RecordingSettingsTab()
            case "editor": return EditorSettingsTab()
            case "beautify": return BeautifySettingsTab()
            case "output": return OutputSettingsTab()
            case "cloud": return CloudSettingsTab()
            case "advanced": return AdvancedSettingsTab()
            default: return AboutSettingsTab()
            }
        }
    )
}

// MARK: - Cloud

final class CloudSettingsTab: SettingsTabViewController {
    override func setupContent() {
        let providerSection = addSection(title: "Provider", anchor: "cloud.provider")
        let provider = NSPopUpButton()
        for p in CloudProvider.allCases { provider.addItem(withTitle: p.presentableName) }
        provider.selectItem(at: CloudProvider.allCases.firstIndex(of: Preferences.cloudProvider) ?? 0)
        provider.target = self
        provider.action = #selector(changeProvider(_:))
        addRow(to: providerSection, title: "Upload to",
               subtitle: "CleanShot Cloud is proprietary; bring your own S3-compatible storage or use imgbb.",
               accessory: provider)

        let auto = makeToggle(Preferences.uploadAfterCapture, target: self, action: #selector(toggleAuto(_:)))
        addRow(to: providerSection, title: "Upload after capture",
               subtitle: "Automatically upload every capture and copy the link.", accessory: auto)

        let s3 = addSection(title: "S3 / R2", anchor: "cloud.s3")
        addRow(to: s3, title: "Access Key ID", subtitle: "Your S3/R2 access key.",
               accessory: field(Preferences.s3Config.accessKey, #selector(s3AccessKey(_:)), secure: false))
        addRow(to: s3, title: "Secret Access Key", subtitle: "Stored in the Keychain.",
               accessory: field(Preferences.s3SecretKey, #selector(s3Secret(_:)), secure: true))
        addRow(to: s3, title: "Bucket", subtitle: "Destination bucket name.",
               accessory: field(Preferences.s3Config.bucket, #selector(s3Bucket(_:)), secure: false))
        addRow(to: s3, title: "Region", subtitle: "e.g. us-east-1 (S3) or auto (R2).",
               accessory: field(Preferences.s3Config.region, #selector(s3Region(_:)), secure: false))
        addRow(to: s3, title: "Endpoint host", subtitle: "e.g. s3.amazonaws.com or <acct>.r2.cloudflarestorage.com.",
               accessory: field(Preferences.s3Config.endpointHost, #selector(s3Endpoint(_:)), secure: false))
        addRow(to: s3, title: "Public base URL", subtitle: "Optional, e.g. https://cdn.example.com — the share link uses this.",
               accessory: field(Preferences.s3Config.publicBaseURL, #selector(s3PublicURL(_:)), secure: false))
        let pathStyle = makeToggle(Preferences.s3Config.usePathStyle, target: self, action: #selector(s3PathStyle(_:)))
        addRow(to: s3, title: "Path-style URLs", subtitle: "On for R2 / MinIO; off for AWS virtual-hosted.", accessory: pathStyle)
        let acl = makeToggle(Preferences.s3Config.setPublicACL, target: self, action: #selector(s3ACL(_:)))
        addRow(to: s3, title: "Set public-read ACL", subtitle: "On for AWS S3 public objects; off for R2.", accessory: acl)

        let imgbb = addSection(title: "imgbb", anchor: "cloud.imgbb")
        addRow(to: imgbb, title: "API Key", subtitle: "From your imgbb.com account.",
               accessory: field(Preferences.imgbbAPIKey, #selector(imgbbKey(_:)), secure: true))
    }

    private func field(_ value: String, _ action: Selector, secure: Bool) -> NSTextField {
        let f = secure ? NSSecureTextField() : NSTextField()
        f.stringValue = value
        f.target = self
        f.action = action
        f.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return f
    }

    @objc private func changeProvider(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        if CloudProvider.allCases.indices.contains(i) { Preferences.cloudProvider = CloudProvider.allCases[i] }
    }
    @objc private func toggleAuto(_ sender: NSSwitch) { Preferences.uploadAfterCapture = (sender.state == .on) }
    @objc private func s3AccessKey(_ s: NSTextField) { var c = Preferences.s3Config; c.accessKey = s.stringValue; Preferences.s3Config = c }
    @objc private func s3Secret(_ s: NSTextField) { Preferences.s3SecretKey = s.stringValue }
    @objc private func s3Bucket(_ s: NSTextField) { var c = Preferences.s3Config; c.bucket = s.stringValue; Preferences.s3Config = c }
    @objc private func s3Region(_ s: NSTextField) { var c = Preferences.s3Config; c.region = s.stringValue; Preferences.s3Config = c }
    @objc private func s3Endpoint(_ s: NSTextField) { var c = Preferences.s3Config; c.endpointHost = s.stringValue; Preferences.s3Config = c }
    @objc private func s3PublicURL(_ s: NSTextField) { var c = Preferences.s3Config; c.publicBaseURL = s.stringValue; Preferences.s3Config = c }
    @objc private func s3PathStyle(_ s: NSSwitch) { var c = Preferences.s3Config; c.usePathStyle = (s.state == .on); Preferences.s3Config = c }
    @objc private func s3ACL(_ s: NSSwitch) { var c = Preferences.s3Config; c.setPublicACL = (s.state == .on); Preferences.s3Config = c }
    @objc private func imgbbKey(_ s: NSTextField) { Preferences.imgbbAPIKey = s.stringValue }
}

// MARK: - General

final class GeneralSettingsTab: SettingsTabViewController {
    private let updater = BetterUpdater.shared

    override func setupContent() {
        let behavior = addSection(title: "Behavior", anchor: "general.behavior")
        let loginSwitch = makeToggle(SMAppService.mainApp.status == .enabled, target: self, action: #selector(toggleLaunchAtLogin(_:)))
        addRow(to: behavior, title: "Launch at login",
               subtitle: "Start automatically when you log in.",
               accessory: loginSwitch, searchItemID: "general.launchAtLogin")

        let updates = addSection(title: "Updates", anchor: "general.updates")
        let autoSwitch = makeToggle(updater.automaticInstallEnabled, target: self, action: #selector(toggleAutoUpdate(_:)))
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
        addRecorder(to: section, title: "All-in-One Capture",
                    subtitle: "Region or window with the full action bar; restores your last selection.",
                    name: .allInOne, searchItemID: "shortcuts.allInOne")
        addRecorder(to: section, title: "Capture Screenshot",
                    subtitle: "Drag out a selection; hold Space to click a window instead.", name: .captureScreenshot,
                    searchItemID: "shortcuts.screenshot")
        addRecorder(to: section, title: "Screenshot & Markup",
                    subtitle: "Select an area, then open the editor with every tool.", name: .screenshotEdit,
                    searchItemID: "shortcuts.markup")
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
        addRecorder(to: recording, title: "Record Window",
                    subtitle: "Click a window to record just that window.", name: .recordWindow,
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

        let downscale = makeToggle(Preferences.downscaleRetina, target: self, action: #selector(toggleDownscale(_:)))
        addRow(to: behavior, title: "Downscale Retina to 1×",
               subtitle: "Halve the pixel size of Retina captures for smaller files.", accessory: downscale)

        let hideIcons = makeToggle(Preferences.hideDesktopIcons, target: self, action: #selector(toggleHideDesktopIcons(_:)))
        addRow(to: behavior, title: "Hide desktop icons",
               subtitle: "Cover desktop icons with the wallpaper during captures and recordings (no Finder relaunch).",
               accessory: hideIcons)

        let timer = addSection(title: "Self-Timer", anchor: "capture.timer")
        let delay = NSPopUpButton()
        for option in Self.delayOptions { delay.addItem(withTitle: Self.delayTitle(option)) }
        delay.selectItem(withTitle: Self.delayTitle(Preferences.captureDelaySeconds))
        delay.target = self
        delay.action = #selector(changeDelay(_:))
        addRow(to: timer, title: "Countdown before capture",
               subtitle: "Wait before a screenshot fires so you can open menus or arrange windows. Press Esc to cancel.",
               accessory: delay)

        let history = addSection(title: "Capture History", anchor: "capture.history")
        let retention = NSPopUpButton()
        for option in CaptureHistoryRetention.allCases { retention.addItem(withTitle: option.presentableName) }
        retention.selectItem(withTitle: Preferences.captureHistoryRetention.presentableName)
        retention.target = self
        retention.action = #selector(changeRetention(_:))
        addRow(to: history, title: "Keep history for",
               subtitle: "How far back the Capture History bar shows captures. Your saved files are never deleted.",
               accessory: retention)
    }

    @objc private func changeAfterAction(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if AfterCaptureAction.allCases.indices.contains(index) {
            Preferences.afterCaptureAction = AfterCaptureAction.allCases[index]
        }
    }

    @objc private func changeRetention(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if CaptureHistoryRetention.allCases.indices.contains(index) {
            Preferences.captureHistoryRetention = CaptureHistoryRetention.allCases[index]
        }
    }

    @objc private func toggleDownscale(_ sender: NSSwitch) { Preferences.downscaleRetina = (sender.state == .on) }
    @objc private func toggleHideDesktopIcons(_ sender: NSSwitch) { Preferences.hideDesktopIcons = (sender.state == .on) }

    static let delayOptions = [0, 3, 5, 10]
    static func delayTitle(_ seconds: Int) -> String { seconds == 0 ? "Off" : "\(seconds) seconds" }

    @objc private func changeDelay(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if Self.delayOptions.indices.contains(index) { Preferences.captureDelaySeconds = Self.delayOptions[index] }
    }
}

// MARK: - Overlay

final class OverlaySettingsTab: SettingsTabViewController {
    override func setupContent() {
        let overlay = addSection(title: "Selection", anchor: "overlay.main")
        let magnifier = makeToggle(Preferences.magnifierEnabled, target: self, action: #selector(toggleMagnifier(_:)))
        addRow(to: overlay, title: "Show magnifier loupe",
               subtitle: "Pixel-accurate zoom with a color readout while selecting.",
               accessory: magnifier, searchItemID: "overlay.magnifier")

        let sound = makeToggle(Preferences.captureSoundEnabled, target: self, action: #selector(toggleSound(_:)))
        addRow(to: overlay, title: "Play capture sound", subtitle: "A shutter sound on capture.", accessory: sound)

        let shadow = makeToggle(Preferences.includeWindowShadow, target: self, action: #selector(toggleWindowShadow(_:)))
        addRow(to: overlay, title: "Include window shadow",
               subtitle: "Keep the drop shadow when capturing a single window.", accessory: shadow)

        let border = makeToggle(Preferences.includeWindowBorder, target: self, action: #selector(toggleWindowBorder(_:)))
        addRow(to: overlay, title: "Include window border",
               subtitle: "Keep the thin edge outline when capturing a single window.", accessory: border)
    }

    @objc private func toggleMagnifier(_ sender: NSSwitch) { Preferences.magnifierEnabled = (sender.state == .on) }
    @objc private func toggleWindowShadow(_ sender: NSSwitch) { Preferences.includeWindowShadow = (sender.state == .on) }
    @objc private func toggleWindowBorder(_ sender: NSSwitch) { Preferences.includeWindowBorder = (sender.state == .on) }
    @objc private func toggleSound(_ sender: NSSwitch) { Preferences.captureSoundEnabled = (sender.state == .on) }
}

// MARK: - Recording

final class RecordingSettingsTab: SettingsTabViewController {
    override func setupContent() {
        let audio = addSection(title: "Audio", anchor: "recording.audio")
        let systemAudio = makeToggle(Preferences.recordSystemAudio, target: self, action: #selector(toggleRecordAudio(_:)))
        addRow(to: audio, title: "Record system audio",
               subtitle: "Include computer audio in screen recordings.",
               accessory: systemAudio, searchItemID: "recording.audio")

        let mic = makeToggle(Preferences.recordMicrophone, target: self, action: #selector(toggleRecordMic(_:)))
        addRow(to: audio, title: "Record microphone",
               subtitle: "Add narration from the mic as a second audio track.", accessory: mic)

        let quality = addSection(title: "Quality", anchor: "recording.quality")
        let fps = NSPopUpButton()
        fps.addItems(withTitles: ["30 fps", "60 fps"])
        fps.selectItem(withTitle: Preferences.recordingFPS == 30 ? "30 fps" : "60 fps")
        fps.target = self
        fps.action = #selector(changeFPS(_:))
        addRow(to: quality, title: "Frame rate",
               subtitle: "Higher is smoother; lower makes smaller files.", accessory: fps)

        let cursor = addSection(title: "Cursor & Clicks", anchor: "recording.cursor")
        let showCursor = makeToggle(Preferences.showCursorInRecording, target: self, action: #selector(toggleShowCursor(_:)))
        addRow(to: cursor, title: "Show cursor",
               subtitle: "Include the mouse pointer in recordings.", accessory: showCursor)

        let clicks = makeToggle(Preferences.highlightClicks, target: self, action: #selector(toggleHighlightClicks(_:)))
        addRow(to: cursor, title: "Highlight mouse clicks",
               subtitle: "Show an animated ring at each click in recordings.", accessory: clicks)

        let overlays = addSection(title: "Overlays", anchor: "recording.overlays")
        let webcam = makeToggle(Preferences.showWebcam, target: self, action: #selector(toggleWebcam(_:)))
        addRow(to: overlays, title: "Webcam overlay",
               subtitle: "Float a round webcam bubble into the recording.", accessory: webcam)

        let keys = makeToggle(Preferences.showKeystrokes, target: self, action: #selector(toggleKeystrokes(_:)))
        addRow(to: overlays, title: "Show keystrokes",
               subtitle: "Display pressed keys (needs Input Monitoring permission).", accessory: keys)

        let focus = addSection(title: "Focus", anchor: "recording.focus")
        let startField = NSTextField(string: Preferences.focusShortcutStart)
        startField.placeholderString = "Shortcut name"
        startField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        startField.target = self
        startField.action = #selector(focusStartChanged(_:))
        addRow(to: focus, title: "Run Shortcut on start",
               subtitle: "macOS has no direct Focus API — name a Shortcut (e.g. one that turns on a Focus) to run when recording starts.",
               accessory: startField)

        let stopField = NSTextField(string: Preferences.focusShortcutStop)
        stopField.placeholderString = "Shortcut name"
        stopField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        stopField.target = self
        stopField.action = #selector(focusStopChanged(_:))
        addRow(to: focus, title: "Run Shortcut on stop",
               subtitle: "Runs when recording stops (e.g. to turn the Focus back off).",
               accessory: stopField)
    }

    @objc private func changeFPS(_ sender: NSPopUpButton) {
        Preferences.recordingFPS = sender.indexOfSelectedItem == 0 ? 30 : 60
    }

    @objc private func focusStartChanged(_ sender: NSTextField) { Preferences.focusShortcutStart = sender.stringValue }
    @objc private func focusStopChanged(_ sender: NSTextField) { Preferences.focusShortcutStop = sender.stringValue }

    @objc private func toggleRecordAudio(_ sender: NSSwitch) { Preferences.recordSystemAudio = (sender.state == .on) }
    @objc private func toggleRecordMic(_ sender: NSSwitch) { Preferences.recordMicrophone = (sender.state == .on) }
    @objc private func toggleWebcam(_ sender: NSSwitch) { Preferences.showWebcam = (sender.state == .on) }
    @objc private func toggleKeystrokes(_ sender: NSSwitch) { Preferences.showKeystrokes = (sender.state == .on) }
    @objc private func toggleHighlightClicks(_ sender: NSSwitch) { Preferences.highlightClicks = (sender.state == .on) }
    @objc private func toggleShowCursor(_ sender: NSSwitch) { Preferences.showCursorInRecording = (sender.state == .on) }
}

// MARK: - Editor

final class EditorSettingsTab: SettingsTabViewController {
    override func setupContent() {
        let steps = addSection(title: "Step Badges", anchor: "editor.steps")

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

        let tools = addSection(title: "Tool Shortcuts", anchor: "editor.tools")
        for tool in ToolKind.allCases {
            let recorder = BetterShortcuts.RecorderCocoa(for: tool.shortcutName, policy: .unrestricted)
            recorder.widthAnchor.constraint(equalToConstant: 170).isActive = true
            addRow(to: tools, title: tool.label, subtitle: "Active while the editor is open.", accessory: recorder)
        }

        let colors = addSection(title: "Colors", anchor: "editor.colors")
        let clearColors = NSButton(title: "Clear", target: self, action: #selector(clearColors))
        clearColors.bezelStyle = .rounded
        addRow(to: colors, title: "Saved colors",
               subtitle: "Forget the editor's saved color palette.", accessory: clearColors)
    }

    @objc private func changeStepFormat(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if StepFormat.allCases.indices.contains(index) { Preferences.stepFormat = StepFormat.allCases[index] }
    }

    @objc private func changeStepStart(_ sender: NSTextField) {
        Preferences.stepStart = max(1, sender.integerValue)
        sender.integerValue = Preferences.stepStart
    }

    @objc private func clearColors() {
        Preferences.recentColors = []
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

// MARK: - Output

final class OutputSettingsTab: SettingsTabViewController {
    private let folderButton = NSButton(title: "", target: nil, action: nil)
    private let templateField = NSTextField()
    private let qualitySlider = NSSlider()

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

        qualitySlider.minValue = 0.1
        qualitySlider.maxValue = 1.0
        qualitySlider.doubleValue = Preferences.jpegQuality
        qualitySlider.isContinuous = false
        qualitySlider.isEnabled = Preferences.format.isLossy
        qualitySlider.target = self
        qualitySlider.action = #selector(changeQuality(_:))
        qualitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        addRow(to: files, title: "Compression quality",
               subtitle: "For JPEG, HEIC, and WebP. Higher keeps more detail; lower makes smaller files.",
               accessory: qualitySlider, searchItemID: "output.quality")

        templateField.stringValue = Preferences.filenameTemplate
        templateField.placeholderString = FilenameTemplate.defaultTemplate
        templateField.target = self
        templateField.action = #selector(changeTemplate(_:))
        templateField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        addRow(to: files, title: "Filename template",
               subtitle: "Tokens: %y year, %n month, %d day, %w weekday, %H %M %S time, %r random. Also {date} {time} {datetime} {n} {mode}.",
               accessory: templateField)
    }

    @objc private func toggleSaveToDisk(_ sender: NSSwitch) {
        Preferences.saveScreenshotsToDisk = (sender.state == .on)
        folderButton.isEnabled = Preferences.saveScreenshotsToDisk
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
        qualitySlider.isEnabled = Preferences.format.isLossy
    }

    @objc private func changeQuality(_ sender: NSSlider) {
        Preferences.jpegQuality = sender.doubleValue
    }

    @objc private func changeTemplate(_ sender: NSTextField) {
        Preferences.filenameTemplate = sender.stringValue
    }
}

// MARK: - Advanced

final class AdvancedSettingsTab: SettingsTabViewController {
    override func setupContent() {
        let maintenance = addSection(title: "Maintenance", anchor: "advanced.maintenance")

        let reset = NSButton(title: "Reset…", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        addRow(to: maintenance, title: "Reset all settings",
               subtitle: "Restore every preference to its default.", accessory: reset)
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
