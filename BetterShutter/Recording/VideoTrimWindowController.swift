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

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)
        super.init()
    }

    func show() {
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
        window.title = "Trim Video"
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

        let export = NSButton(title: "Save Trimmed", target: self, action: #selector(exportTapped))
        if #available(macOS 26.0, *) {
            export.bezelStyle = .glass
        } else {
            export.bezelStyle = .rounded
        }
        export.keyEquivalent = "\r"
        let bottom = NSStackView(views: [rangeLabel, NSView(), export])
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [startRow, endRow, bottom])
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
            controlBar.heightAnchor.constraint(equalToConstant: 116),
            stack.leadingAnchor.constraint(equalTo: controlBar.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: controlBar.contentView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: controlBar.contentView.centerYAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        rangeChanged()
        self.window = window
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

    func windowWillClose(_ notification: Notification) { player.pause() }
}
