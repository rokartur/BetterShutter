import AppKit
import AVKit
import AVFoundation

/// Trims a recorded video: preview with an AVPlayer, start/end sliders, and a passthrough export of
/// the selected range. Non-destructive (writes a new "… trimmed.mp4").
@MainActor
final class VideoTrimWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let url: URL
    private let player: AVPlayer
    private var duration: Double = 0

    private let startSlider = NSSlider()
    private let endSlider = NSSlider()
    private let rangeLabel = NSTextField(labelWithString: "")
    private let bgPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let paddingSlider = NSSlider(value: 0.08, minValue: 0, maxValue: 0.2, target: nil, action: nil)
    // Background options offered for video framing (a curated subset of the beautify library).
    private let bgPresets = BackgroundPreset.all
    private let sizeOptions: [(String, CGFloat?)] = [("Original", nil), ("720p", 720), ("1080p", 1080), ("1440p", 1440)]
    private let followMouseToggle = NSButton(checkboxWithTitle: "Follow Mouse", target: nil, action: nil)
    private var cursorTrack: CursorTrack?

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)
        super.init()
    }

    func show() {
        cursorTrack = CursorTrack.load(for: url)
        Task {
            let asset = AVURLAsset(url: url)
            duration = (try? await asset.load(.duration).seconds) ?? 0
            build()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Edit Video"
        window.delegate = self
        window.center()
        let content = NSView()
        window.contentView = content

        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(playerView)

        startSlider.minValue = 0; startSlider.maxValue = duration; startSlider.doubleValue = 0
        endSlider.minValue = 0; endSlider.maxValue = duration; endSlider.doubleValue = duration
        for s in [startSlider, endSlider] { s.target = self; s.action = #selector(rangeChanged) }

        let startRow = labeledRow("Start", startSlider)
        let endRow = labeledRow("End", endSlider)
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor

        // Background framing controls (wallpaper bg + padding + output size).
        bgPopup.removeAllItems()
        bgPopup.addItem(withTitle: "No Background")
        for preset in bgPresets { bgPopup.addItem(withTitle: preset.name) }
        sizePopup.removeAllItems()
        for (title, _) in sizeOptions { sizePopup.addItem(withTitle: title) }
        paddingSlider.translatesAutoresizingMaskIntoConstraints = false
        paddingSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        followMouseToggle.isEnabled = (cursorTrack != nil)
        followMouseToggle.toolTip = cursorTrack == nil
            ? "Available for full-screen recordings (no cursor track found)"
            : "Auto-zoom toward the cursor"
        let bgRow = NSStackView(views: [
            label2("Background"), bgPopup, label2("Padding"), paddingSlider, label2("Size"), sizePopup,
            followMouseToggle,
        ])
        bgRow.spacing = 6
        bgRow.translatesAutoresizingMaskIntoConstraints = false

        let export = NSButton(title: "Save Trimmed", target: self, action: #selector(exportTapped))
        let beautify = NSButton(title: "Save with Background", target: self, action: #selector(exportBeautifiedTapped))
        for b in [export, beautify] {
            if #available(macOS 26.0, *) { b.bezelStyle = .glass } else { b.bezelStyle = .rounded }
        }
        export.keyEquivalent = "\r"
        let bottom = NSStackView(views: [rangeLabel, NSView(), beautify, export])
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [startRow, endRow, bgRow, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The trim controls ride a Liquid Glass bar (regular glass on 26, vibrancy fallback below).
        let controlBar = GlassPanelView(cornerRadius: GlassTokens.Radius.bar)
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBar.contentView.addSubview(stack)
        content.addSubview(controlBar)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: controlBar.topAnchor, constant: -10),

            controlBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controlBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            controlBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            // Fixed height (not tied to the stack) avoids a layout-recursion loop with the glass
            // view re-laying out its contentView.
            controlBar.heightAnchor.constraint(equalToConstant: 150),
            stack.leadingAnchor.constraint(equalTo: controlBar.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: controlBar.contentView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: controlBar.contentView.centerYAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        rangeChanged()
        self.window = window
    }

    private func label2(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func labeledRow(_ title: String, _ slider: NSSlider) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 44).isActive = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, slider])
        row.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return row
    }

    @objc private func rangeChanged() {
        if endSlider.doubleValue <= startSlider.doubleValue {
            endSlider.doubleValue = min(duration, startSlider.doubleValue + 0.1)
        }
        rangeLabel.stringValue = String(format: "%.1fs – %.1fs of %.1fs", startSlider.doubleValue, endSlider.doubleValue, duration)
        player.seek(to: CMTime(seconds: startSlider.doubleValue, preferredTimescale: 600))
    }

    @objc private func exportTapped() {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return }
        let out = url.deletingPathExtension().appendingPathExtension("trimmed.mp4")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: startSlider.doubleValue, preferredTimescale: 600),
            end: CMTime(seconds: endSlider.doubleValue, preferredTimescale: 600)
        )
        export.exportAsynchronously {
            // Read status on the export's own queue, then hand only Sendable values to the main actor.
            let succeeded = export.status == .completed
            Task { @MainActor in
                if succeeded {
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                } else {
                    HUD.show("Trim failed")
                }
            }
        }
    }

    @objc private func exportBeautifiedTapped() {
        let bgIndex = bgPopup.indexOfSelectedItem - 1   // 0 = "No Background"
        guard bgPresets.indices.contains(bgIndex) else { HUD.show("Pick a background"); return }
        let background = bgPresets[bgIndex].fill
        let sizeIndex = sizePopup.indexOfSelectedItem
        let targetHeight = sizeOptions.indices.contains(sizeIndex) ? sizeOptions[sizeIndex].1 : nil
        let follow = (followMouseToggle.state == .on) && (cursorTrack != nil)
        let options = VideoBeautify.Options(background: background,
                                            paddingFraction: CGFloat(paddingSlider.doubleValue),
                                            targetHeight: targetHeight,
                                            cursorTrack: cursorTrack,
                                            followZoom: follow ? 2.0 : 1)
        let range = CMTimeRange(
            start: CMTime(seconds: startSlider.doubleValue, preferredTimescale: 600),
            end: CMTime(seconds: endSlider.doubleValue, preferredTimescale: 600)
        )
        let out = url.deletingPathExtension().appendingPathExtension("framed.mp4")
        HUD.show("Rendering…", duration: 1.0)
        Task {
            let result = await VideoBeautify.export(url: url, options: options, timeRange: range, to: out)
            if let result {
                NSWorkspace.shared.activateFileViewerSelecting([result])
            } else {
                HUD.show("Export failed")
            }
        }
    }

    func windowWillClose(_ notification: Notification) { player.pause() }
}
