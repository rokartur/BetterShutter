import AppKit
import AVKit
import AVFoundation

/// Trims a recorded video: preview with an AVPlayer, start/end sliders, and a passthrough export of
/// the selected range. Non-destructive (writes a new "… trimmed.mp4").
@MainActor
final class VideoTrimWindowController: NSObject, NSWindowDelegate {
    private nonisolated final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    private var window: NSWindow?
    private let url: URL
    private let player: AVPlayer
    private var duration: Double = 0
    /// Set by `close()`. The window is built asynchronously (after the asset's duration loads), so
    /// a close that races the build must cancel it — otherwise the "closed" trimmer's window still
    /// appears and lingers as a zombie.
    private var isClosed = false
    private var didTearDown = false
    private var loadTask: Task<Void, Never>?
    private var beautifyTask: Task<Void, Never>?
    private var activeExportSession: AVAssetExportSession?
    private var activeExportID: UUID?

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
    /// Fired from `windowWillClose` so the owner can release its strong reference — without it the
    /// controller (and its whole AVPlayer decode pipeline) lingers until the next trim or app quit.
    var onClose: (() -> Void)?

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)
        super.init()
    }

    func show() {
        cursorTrack = CursorTrack.load(for: url)
        let inputURL = url
        loadTask = Task { [weak self] in
            let asset = AVURLAsset(url: inputURL)
            let loadedDuration = (try? await asset.load(.duration).seconds) ?? 0
            guard let self else { return }
            self.duration = loadedDuration
            guard !Task.isCancelled, !self.isClosed else {
                // Closed while loading: never build the window, and release the player pipeline
                // now (windowWillClose won't run for a window that never existed).
                self.player.replaceCurrentItem(with: nil)
                return
            }
            self.loadTask = nil
            self.build()
            self.window?.makeKeyAndOrderFront(nil)
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

    /// Exports always land in the user's save directory — the source may live in the unsaved-
    /// recordings scratch folder (After-Capture Save off), and an explicit "Save …" must never
    /// write somewhere the user will lose.
    private struct ExportDestination {
        let staging: URL
        let directory: URL
        let filename: String
    }

    private func exportDestination(suffix: String) -> ExportDestination {
        let dir = Preferences.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        return ExportDestination(
            staging: dir.appendingPathComponent(
                ".BetterShutter-export-\(UUID().uuidString).mp4", isDirectory: false),
            directory: dir,
            filename: "\(base).\(suffix).mp4")
    }

    @objc private func exportTapped() {
        guard activeExportID == nil else { HUD.show("An export is already running"); return }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return }
        let destination = exportDestination(suffix: "trimmed")
        let exportID = UUID()
        activeExportID = exportID
        activeExportSession = export
        // Completion owns the session explicitly even after window teardown clears the controller's
        // reference, guaranteeing status read + UUID staging cleanup after cancellation.
        let exportBox = ExportSessionBox(export)
        export.outputURL = destination.staging
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: startSlider.doubleValue, preferredTimescale: 600),
            end: CMTime(seconds: endSlider.doubleValue, preferredTimescale: 600)
        )
        export.exportAsynchronously { [weak self] in
            // Read status on the export's own queue, then hand only Sendable values to the main actor.
            let succeeded = exportBox.session.status == .completed
            let published: URL?
            if succeeded {
                published = try? AtomicFilePublisher.publish(
                    staging: destination.staging,
                    in: destination.directory,
                    filename: destination.filename)
            } else {
                published = nil
            }
            if published == nil { try? FileManager.default.removeItem(at: destination.staging) }
            Task { @MainActor in
                guard let self, self.activeExportID == exportID else { return }
                self.activeExportSession = nil
                self.activeExportID = nil
                guard !self.isClosed else { return }
                if let published {
                    NSWorkspace.shared.activateFileViewerSelecting([published])
                } else {
                    HUD.show("Trim failed")
                }
            }
        }
    }

    @objc private func exportBeautifiedTapped() {
        guard activeExportID == nil else { HUD.show("An export is already running"); return }
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
        let destination = exportDestination(suffix: "framed")
        let exportID = UUID()
        activeExportID = exportID
        HUD.show("Rendering…", duration: 1.0)
        let inputURL = url
        let task = Task { [weak self] in
            let rendered = await VideoBeautify.export(
                url: inputURL, options: options, timeRange: range, to: destination.staging)
            let result: URL?
            if rendered != nil, !Task.isCancelled {
                let publish = Task.detached(priority: .utility) {
                    try? AtomicFilePublisher.publish(
                        staging: destination.staging,
                        in: destination.directory,
                        filename: destination.filename)
                }
                result = await withTaskCancellationHandler {
                    await publish.value
                } onCancel: {
                    publish.cancel()
                }
            } else {
                result = nil
            }
            if result == nil { try? FileManager.default.removeItem(at: destination.staging) }
            guard let self, self.activeExportID == exportID else { return }
            self.beautifyTask = nil
            self.activeExportID = nil
            guard !self.isClosed else { return }
            if let result {
                NSWorkspace.shared.activateFileViewerSelecting([result])
            } else {
                HUD.show("Export failed")
            }
        }
        beautifyTask = task
    }

    /// Programmatic close (e.g. the owner replacing this trimmer with a new one); routes through
    /// `windowWillClose` so the player pipeline is torn down and `onClose` still fires. If the
    /// window hasn't been built yet, the flag makes the pending build bail instead.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let window {
            window.close()
        } else {
            tearDown()
        }
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        tearDown()
    }

    private func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        loadTask?.cancel()
        loadTask = nil
        beautifyTask?.cancel()
        beautifyTask = nil
        activeExportSession?.cancelExport()
        activeExportSession = nil
        activeExportID = nil
        player.pause()
        player.replaceCurrentItem(with: nil)   // release the asset + decode pipeline now, not at dealloc
        window = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}
