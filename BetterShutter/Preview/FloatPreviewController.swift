import AppKit

/// Shows the post-capture float preview near the bottom-left of the active screen, auto-dismissing
/// after a few seconds unless the user is interacting with it.
@MainActor
final class FloatPreviewController {
    private var window: FloatPreviewWindow?
    private var dismissTimer: Timer?

    var onAnnotate: ((CapturedImage, CaptureMode) -> Void)?
    var onBeautify: ((CapturedImage, CaptureMode) -> Void)?

    private let autoDismissDelay: TimeInterval = 6

    func show(_ image: CapturedImage, mode: CaptureMode, savedURL: URL?) {
        dismiss()

        let view = FloatPreviewView(image: image, mode: mode, savedURL: savedURL)
        view.onCopy = { PasteboardWriter.copy(image.cgImage) }
        view.onSave = { Task.detached { _ = try? FileSaver.save(image.cgImage, mode: mode) } }
        view.onClose = { [weak self] in self?.fadeOutAndDismiss() }
        view.onAnnotate = { [weak self] in
            self?.dismiss()
            self?.onAnnotate?(image, mode)
        }
        view.onBeautify = { [weak self] in
            self?.dismiss()
            self?.onBeautify?(image, mode)
        }
        view.onHoverChange = { [weak self] hovered in
            if hovered { self?.cancelTimer() } else { self?.startTimer() }
        }

        let panel = FloatPreviewWindow(size: FloatPreviewView.cardSize)
        panel.contentView = view
        position(panel)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        window = panel
        startTimer()
    }

    func dismiss() {
        cancelTimer()
        window?.orderOut(nil)
        window = nil
    }

    private func fadeOutAndDismiss() {
        cancelTimer()
        guard let panel = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.window?.orderOut(nil)
                self?.window = nil
            }
        })
    }

    private func position(_ panel: FloatPreviewWindow) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let margin: CGFloat = 20
        let origin = CGPoint(x: visible.minX + margin, y: visible.minY + margin)
        panel.setFrameOrigin(origin)
    }

    private func startTimer() {
        cancelTimer()
        dismissTimer = Timer.scheduledTimer(
            timeInterval: autoDismissDelay, target: self,
            selector: #selector(timerFired), userInfo: nil, repeats: false
        )
    }

    private func cancelTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    @objc private func timerFired() { fadeOutAndDismiss() }
}
