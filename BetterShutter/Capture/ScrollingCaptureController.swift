import AppKit

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
    private var bar: ScrollCaptureBar?
    private var active = false
    private var busy = false

    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var sourceRectPoints: CGRect = .zero
    /// First frame (visual top of the result). Revealed strips accumulate in `strips` and are
    /// composited once on Done — per-tick work stays O(strip) instead of re-rendering the whole
    /// growing canvas every 200 ms.
    private var head: CapturedImage?
    private var strips: [CapturedImage] = []
    private var stitchedHeight = 0
    private var lastFrame: ScrollStitcher.Frame?

    private let interval: TimeInterval = 0.2

    func begin() {
        guard !active, !overlay.isPresenting else { return }
        guard PermissionsService.shared.ensureAuthorizedOrGuide() else { return }
        active = true
        Task {
            do {
                let frozen = try await engine.freezeAllDisplays()
                let content = try await engine.shareableContent()
                overlay.present(
                    frozen: frozen,
                    windows: content.windows,
                    magnifierEnabled: false,
                    onRegion: { [weak self] _, globalRect, displayID, _ in
                        self?.startSession(globalRect: globalRect, displayID: displayID)
                    },
                    onWindow: { [weak self] _ in self?.active = false },
                    onCancel: { [weak self] in self?.active = false }
                )
            } catch {
                active = false
                PermissionsService.shared.handleCaptureError(error)
            }
        }
    }

    // MARK: Session

    private func startSession(globalRect: CGRect, displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            active = false
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
        self.lastFrame = nil

        showBar(near: screen)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick() // grab the first frame immediately
    }

    private func tick() {
        guard active, !busy else { return }
        busy = true
        let id = displayID, rect = sourceRectPoints
        Task {
            defer { busy = false }
            guard let frame = try? await engine.captureRegion(displayID: id, sourceRectPoints: rect) else { return }
            await ingest(frame)
        }
    }

    private func ingest(_ image: CapturedImage) async {
        let prevFrame = lastFrame
        let isFirst = head == nil
        let result: (piece: CapturedImage?, frame: ScrollStitcher.Frame)? = await Task.detached {
            guard let nf = ScrollStitcher.makeFrame(image.cgImage) else { return nil }
            guard let pf = prevFrame, !isFirst else {
                return (image, nf) // first frame seeds the head
            }
            let dy = ScrollStitcher.bestShift(prev: pf.signature, next: nf.signature)
            guard dy > 0, let strip = ScrollStitcher.strip(from: image.cgImage, rows: dy) else {
                return (nil, nf) // no new content; just advance the reference frame
            }
            return (CapturedImage(cgImage: strip, scale: image.scale, displayID: image.displayID), nf)
        }.value

        guard active, let (piece, newFrame) = result else { return }
        lastFrame = newFrame
        if isFirst, let piece {
            head = piece
            stitchedHeight = piece.cgImage.height
        } else if let piece {
            strips.append(piece)
            stitchedHeight += piece.cgImage.height
        }
        bar?.update(heightPx: stitchedHeight)
    }

    // MARK: Finish

    private func done() {
        stop()
        guard let head else { reset(); return }
        let strips = self.strips
        if strips.count > 20 { HUD.show("Stitching…", duration: 1.0) }
        Task {
            let stitched: CGImage? = strips.isEmpty ? head.cgImage : await Task.detached {
                ScrollStitcher.composite(head: head.cgImage, strips: strips.map(\.cgImage))
            }.value
            if let stitched {
                CaptureCoordinator.shared.deliver(
                    CapturedImage(cgImage: stitched, scale: head.scale, displayID: head.displayID),
                    mode: .region)
            }
            reset()
        }
    }

    private func cancel() {
        stop()
        reset()
    }

    private func stop() {
        active = false          // gate any in-flight tick/ingest before tearing down
        timer?.invalidate()
        timer = nil
        bar?.dismiss()
        bar = nil
    }

    private func reset() {
        head = nil
        strips = []
        stitchedHeight = 0
        lastFrame = nil
    }

    // MARK: Bar

    private func showBar(near screen: NSScreen) {
        let bar = ScrollCaptureBar()
        bar.onDone = { [weak self] in self?.done() }
        bar.onCancel = { [weak self] in self?.cancel() }
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
