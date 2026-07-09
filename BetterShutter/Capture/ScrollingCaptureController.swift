import AppKit

/// Owns the large retained stitch inputs across the detached composite, then releases them before
/// the final bitmap enters beautify/output. Access is strictly sequential (worker, then MainActor).
private nonisolated final class ScrollCompositeSources: @unchecked Sendable {
    private var head: CGImage?
    private var strips: [CGImage]

    init(head: CGImage, strips: [CGImage]) {
        self.head = head
        self.strips = strips
    }

    func composite() -> CGImage? {
        guard let head else { return nil }
        return strips.isEmpty ? head : ScrollStitcher.composite(head: head, strips: strips)
    }

    func releaseBitmaps() {
        head = nil
        strips.removeAll(keepingCapacity: false)
    }
}

/// Drives scrolling capture: pick a region, then repeatedly grab it while the user scrolls,
/// stitching each newly-revealed strip into one tall image (via `ScrollStitcher`). A small
/// glass control bar shows the growing height; Done delivers the result, Cancel discards it.
///
/// The stitching math is unit-tested (`ScrollStitcherTests`); the live scroll loop itself needs a
/// human to scroll a real window to fully validate.
@MainActor
final class ScrollingCaptureController {
    static let shared = ScrollingCaptureController()

    private let engine = CaptureEngine()
    private let overlay = OverlayController()

    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var bar: ScrollCaptureBar?
    private var active = false
    /// Releases CaptureCoordinator's global capture gate on every terminal path. Retained only for
    /// the lifetime of one session and cleared before invocation.
    private var onEnd: (() -> Void)?
    /// Identifies the session that currently has a capture in flight. Keeping the generation (rather
    /// than a plain Bool) prevents a late task from an old session from clearing the busy state of a
    /// newly-started one.
    private var busyGeneration: UInt64?
    /// Every start/stop changes this token. ScreenCaptureKit and stitching both suspend, so without a
    /// token an old frame can resume after Done/Cancel and be appended to the next session.
    private var sessionGeneration: UInt64 = 0

    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var sourceRectPoints: CGRect = .zero
    /// First frame (visual top of the result). Revealed strips accumulate in `strips` and are
    /// composited once on Done — per-tick work stays O(strip) instead of re-rendering the whole
    /// growing canvas every 200 ms.
    private var head: CapturedImage?
    private var strips: [CapturedImage] = []
    private var stitchedHeight = 0
    private var retainedBitmapBytes = 0
    private var lastFrame: ScrollStitcher.Frame?
    private var consecutiveCaptureFailures = 0

    private let interval: TimeInterval = 0.2

    @discardableResult
    func begin(onEnd: @escaping () -> Void) -> Bool {
        guard !active, self.onEnd == nil, !overlay.isPresenting else { return false }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return false }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        self.onEnd = onEnd
        active = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let frozen = try await engine.freezeAllDisplays()
                guard active, sessionGeneration == generation else { return }
                let content = try await engine.shareableContent()
                guard active, sessionGeneration == generation else { return }
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: false,
                    onRegion: { [weak self] _, globalRect, displayID, _ in
                        self?.startSession(globalRect: globalRect, displayID: displayID,
                                           generation: generation)
                    },
                    onWindow: { [weak self] _ in self?.cancel(generation: generation) },
                    onCancel: { [weak self] in self?.cancel(generation: generation) }
                )
            } catch {
                guard active, sessionGeneration == generation else { return }
                cancel(generation: generation)
                PermissionsService.shared.handleCaptureError(error)
            }
        }
        return true
    }

    // MARK: Session

    private func startSession(globalRect: CGRect, displayID: CGDirectDisplayID,
                              generation: UInt64) {
        guard active, sessionGeneration == generation else { return }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            cancel(generation: generation)
            return
        }
        let frame = screen.frame
        // SCStream sourceRect is display-local points, top-left origin.
        self.sourceRectPoints = CGRect(
            x: globalRect.minX - frame.minX,
            y: frame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
        self.displayID = displayID
        self.head = nil
        self.strips = []
        self.stitchedHeight = 0
        self.retainedBitmapBytes = 0
        self.lastFrame = nil
        self.consecutiveCaptureFailures = 0

        showBar(near: screen, generation: generation)
        installSessionScreenObserver(generation: generation)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(generation: generation) }
        }
        tick(generation: generation) // grab the first frame immediately
    }

    private func tick(generation: UInt64) {
        guard active, sessionGeneration == generation, busyGeneration != generation else { return }
        busyGeneration = generation
        let id = displayID, rect = sourceRectPoints
        Task {
            defer {
                // A newer session may already own the busy marker.
                if busyGeneration == generation { busyGeneration = nil }
            }
            do {
                let frame = try await engine.captureRegion(displayID: id, sourceRectPoints: rect)
                guard active, generation == sessionGeneration else { return }
                consecutiveCaptureFailures = 0
                await ingest(frame, generation: generation)
            } catch {
                guard active, generation == sessionGeneration else { return }
                consecutiveCaptureFailures += 1
                // A disconnected display or revoked capture source otherwise leaves the 5 Hz timer
                // retrying forever. Allow brief SCK hiccups, then terminate the session cleanly.
                if consecutiveCaptureFailures >= 3 {
                    HUD.show("Scrolling capture stopped")
                    cancel(generation: generation)
                }
            }
        }
    }

    private func installSessionScreenObserver(generation: UInt64) {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // The selected display geometry/source may no longer exist. Cancel rather than leaving
            // the timer and its repeated ScreenCaptureKit requests alive off-screen. The observer's
            // callback may already be queued when removal occurs, so preserve the owning token: a
            // delayed callback from session A must never cancel a newly-started session B.
            MainActor.assumeIsolated { self?.cancel(generation: generation) }
        }
    }

    private func ingest(_ image: CapturedImage, generation: UInt64) async {
        guard active, generation == sessionGeneration else { return }
        let prevFrame = lastFrame
        let isFirst = head == nil
        let currentBytes = retainedBitmapBytes
        let currentHeight = stitchedHeight
        let result: (piece: CapturedImage?, frame: ScrollStitcher.Frame, reachedLimit: Bool)? = await Task.detached {
            guard let nf = ScrollStitcher.makeFrame(image.cgImage) else { return nil }
            guard let pf = prevFrame, !isFirst else {
                let fits = ScrollStitcher.canRetain(
                    currentBytes: currentBytes,
                    currentHeight: currentHeight,
                    candidateBytesPerRow: image.cgImage.bytesPerRow,
                    candidateHeight: image.cgImage.height)
                return fits ? (image, nf, false) : (nil, nf, true) // first frame seeds the head
            }
            let dy = ScrollStitcher.bestShift(prev: pf.signature, next: nf.signature)
            guard dy > 0, let strip = ScrollStitcher.strip(from: image.cgImage, rows: dy) else {
                return (nil, nf, false) // no new content; just advance the reference frame
            }
            let fits = ScrollStitcher.canRetain(
                currentBytes: currentBytes,
                currentHeight: currentHeight,
                candidateBytesPerRow: strip.bytesPerRow,
                candidateHeight: strip.height)
            guard fits else { return (nil, nf, true) }
            return (CapturedImage(cgImage: strip, scale: image.scale, displayID: image.displayID), nf, false)
        }.value

        guard active, generation == sessionGeneration,
              let (piece, newFrame, reachedLimit) = result else { return }
        if reachedLimit {
            HUD.show("Maximum scrolling capture size reached")
            done(generation: generation)
            return
        }
        lastFrame = newFrame
        if isFirst, let piece {
            head = piece
            stitchedHeight = piece.cgImage.height
            retainedBitmapBytes = piece.cgImage.bytesPerRow * piece.cgImage.height
        } else if let piece {
            strips.append(piece)
            stitchedHeight += piece.cgImage.height
            retainedBitmapBytes += piece.cgImage.bytesPerRow * piece.cgImage.height
        }
        bar?.update(heightPx: stitchedHeight)
    }

    // MARK: Finish

    private func done(generation: UInt64? = nil) {
        guard active else { return }
        if let generation, generation != sessionGeneration { return }
        // Keep CaptureCoordinator's global gate until compositing and delivery finish. Releasing it
        // here would let another capture overwrite shared output state while this task is suspended.
        stop(notifyEnd: false)
        guard let head else {
            reset()
            finishActivity()
            return
        }
        let stripCount = strips.count
        let sources = ScrollCompositeSources(head: head.cgImage, strips: strips.map(\.cgImage))
        let scale = head.scale
        let displayID = head.displayID
        // The snapshots below own everything the potentially long composite needs. Clear the
        // controller's mutable session slots before suspension so completion never resets later state.
        reset()
        if stripCount > 20 { HUD.show("Stitching…", duration: 1.0) }
        Task {
            let stitched = await Task.detached { sources.composite() }.value
            // The composite owns its pixels. Drop up to 256 MiB of source strips before deliver()
            // can allocate an auto-beautified output and encoder scratch buffers.
            sources.releaseBitmaps()
            if let stitched {
                CaptureCoordinator.shared.deliver(
                    CapturedImage(cgImage: stitched, scale: scale, displayID: displayID),
                    mode: .region)
            }
            finishActivity()
        }
    }

    private func cancel(generation: UInt64? = nil) {
        guard active else { return }
        if let generation, generation != sessionGeneration { return }
        stop()
        reset()
    }

    private func stop(notifyEnd: Bool = true) {
        active = false          // gate any in-flight tick/ingest before tearing down
        sessionGeneration &+= 1 // invalidate work suspended in ScreenCaptureKit / stitching
        timer?.invalidate()
        timer = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        bar?.dismiss()
        bar = nil
        if notifyEnd { finishActivity() }
    }

    private func finishActivity() {
        let completion = onEnd
        onEnd = nil
        completion?()
    }

    private func reset() {
        head = nil
        strips = []
        stitchedHeight = 0
        retainedBitmapBytes = 0
        lastFrame = nil
        consecutiveCaptureFailures = 0
    }

    // MARK: Bar

    private func showBar(near screen: NSScreen, generation: UInt64) {
        let bar = ScrollCaptureBar()
        bar.onDone = { [weak self] in self?.done(generation: generation) }
        bar.onCancel = { [weak self] in self?.cancel(generation: generation) }
        bar.present(near: screen)
        self.bar = bar
    }
}

/// Liquid-glass control bar for a scrolling-capture session.
@MainActor
private final class ScrollCaptureBar {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private var window: NSPanel?
    private let label = NSTextField(labelWithString: "Scroll the content…")

    func present(near screen: NSScreen) {
        let size = NSSize(width: 280, height: 44)
        let panel = NSPanel.glassChrome(size: size, level: .statusBar)
        let glass = GlassPanelView(cornerRadius: 14)
        glass.frame = NSRect(origin: .zero, size: size)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor

        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .accessoryBarAction
        done.controlSize = .small
        done.keyEquivalent = "\r"

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .accessoryBarAction
        cancel.controlSize = .small

        let stack = NSStackView(views: [label, done, cancel])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
        ])
        panel.contentView = glass

        let x = screen.frame.midX - size.width / 2
        let y = screen.visibleFrame.maxY - size.height - 16
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        panel.orderFront(nil)
        window = panel
    }

    func update(heightPx: Int) {
        label.stringValue = "Captured \(heightPx) px — keep scrolling…"
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }

    @objc private func doneTapped() { onDone?() }
    @objc private func cancelTapped() { onCancel?() }
}
