import AppKit
import Quartz

/// The post-capture quick-access overlay: captures park in the bottom-right corner of the capture's
/// screen and stack as a column of cards (newest nearest the corner). Each card auto-dismisses after
/// a delay unless the pointer is over the stack. While the pointer is over the stack the app takes
/// focus so ⌘W (via a local key monitor) dismisses the card under the pointer; focus returns to the
/// previously-active app once the pointer truly leaves the stack.
@MainActor
final class FloatPreviewController {

    private var panels: [FloatPreviewWindow] = []
    private var cardViews: [ObjectIdentifier: FloatPreviewView] = [:]
    private var cardInfo: [ObjectIdentifier: (image: CapturedImage, mode: CaptureMode, url: URL?)] = [:]
    private var timers: [ObjectIdentifier: Timer] = [:]
    private var hoveredPanels: Set<ObjectIdentifier> = []
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var anchorScreen: NSScreen?
    private var idleWork: DispatchWorkItem?
    /// The most recently dismissed capture, for "Restore Closed Quick Access".
    private var lastClosed: (image: CapturedImage, mode: CaptureMode, url: URL?)?

    var onAnnotate: ((CapturedImage, CaptureMode) -> Void)?
    var onBeautify: ((CapturedImage, CaptureMode) -> Void)?

    private let autoDismissDelay: TimeInterval = 8
    private let hardCardCap = 5
    private let spacing: CGFloat = 12
    private let margin: CGFloat = 20

    func show(_ image: CapturedImage, mode: CaptureMode, savedURL: URL?) {
        if panels.isEmpty { anchorScreen = Self.screen(for: image) }

        let cardSize = FloatPreviewView.cardSize(for: image.pixelSize)
        let view = FloatPreviewView(image: image, mode: mode, savedURL: savedURL)
        view.autoresizingMask = [.width, .height]

        // The card is the screenshot itself (full-bleed); no glass chrome behind it.
        let panel = FloatPreviewWindow(size: cardSize)
        view.frame = NSRect(origin: .zero, size: cardSize)
        panel.contentView = view
        let id = ObjectIdentifier(panel)

        view.onCopy = { [weak view] in PasteboardWriter.copy(image.cgImage); view?.showCopyFeedback() }
        view.onSave = { Task.detached { _ = try? FileSaver.save(image.cgImage, mode: mode) } }
        view.onClose = { [weak self, weak panel] in if let panel { self?.remove(panel, animated: true) } }
        view.onAnnotate = { [weak self, weak panel] in
            if let panel { self?.remove(panel, animated: false) }
            self?.onAnnotate?(image, mode)
        }
        view.onBeautify = { [weak self, weak panel] in
            if let panel { self?.remove(panel, animated: false) }
            self?.onBeautify?(image, mode)
        }
        view.onPin = { [weak self, weak panel] in
            if let panel { self?.remove(panel, animated: false) }
            PinController.shared.pin(image)
        }
        view.onShare = { [weak view] in
            guard let view else { return }
            let picker = NSSharingServicePicker(items: [NSImage(cgImage: image.cgImage, size: image.pixelSize)])
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minX)
        }
        view.onHoverChange = { [weak self, weak panel] hovered in
            guard let self, let panel else { return }
            if hovered { self.beginHover(panel) } else { self.endHover(panel) }
        }

        installKeyMonitorIfNeeded()
        panels.append(panel)
        cardViews[id] = view
        cardInfo[id] = (image, mode, savedURL)

        // Evict the oldest cards that no longer fit (height-bounded), before positioning the new one.
        let available = anchorVisibleFrame().height - 2 * margin
        while panels.count > 1, panels.count > hardCardCap || stackedHeight() > available,
              let oldest = panels.first {
            evict(oldest)
        }

        let origins = layout()
        if let target = origins[id] { panel.setFrameOrigin(target) }
        panel.alphaValue = 0
        panel.orderFront(nil)
        repositionAll(animated: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        ensureTimersIfIdle()
    }

    /// Dismiss every card (e.g. on quit).
    func dismissAll() {
        cancelIdleWork()
        for panel in panels { cancelTimer(for: panel); panel.orderOut(nil) }
        panels.removeAll()
        cardViews.removeAll()
        cardInfo.removeAll()
        timers.removeAll()
        hoveredPanels.removeAll()
        removeKeyMonitor()
        restoreFocus()
    }

    // MARK: Stacking

    private func anchorVisibleFrame() -> CGRect {
        (anchorScreen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
    }

    /// Total height the current column of (variable-height) cards occupies, including gaps.
    private func stackedHeight() -> CGFloat {
        guard !panels.isEmpty else { return 0 }
        let heights = panels.reduce(0) { $0 + $1.frame.height }
        return heights + CGFloat(panels.count - 1) * spacing
    }

    /// Target origin for each card: the oldest sits at the bottom-right corner and newer captures
    /// stack upward above it (so a fresh capture appears on top). When the oldest auto-dismisses, the
    /// cards above slide down to fill the gap. Positions summed bottom-up.
    private func layout() -> [ObjectIdentifier: CGPoint] {
        let visible = anchorVisibleFrame()
        var y = visible.minY + margin
        var result: [ObjectIdentifier: CGPoint] = [:]
        for panel in panels {                          // oldest (first) at the corner, newest on top
            // Right-anchor per card: portrait cards are narrower, so anchor by each card's own width.
            let x = visible.maxX - margin - panel.frame.width
            result[ObjectIdentifier(panel)] = CGPoint(x: x, y: y)
            y += panel.frame.height + spacing
        }
        return result
    }

    private func repositionAll(animated: Bool) {
        let origins = layout()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.22 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for panel in panels {
                guard let target = origins[ObjectIdentifier(panel)] else { continue }
                if animated { panel.animator().setFrameOrigin(target) } else { panel.setFrameOrigin(target) }
            }
        }
    }

    /// Tear down a card with no hover/focus reconciliation (used for overflow eviction).
    private func evict(_ panel: FloatPreviewWindow) {
        guard let index = panels.firstIndex(of: panel) else { return }
        let id = ObjectIdentifier(panel)
        cancelTimer(for: panel)
        hoveredPanels.remove(id)
        // Overflow eviction is not a user close — don't overwrite the restore target.
        cardInfo[id] = nil
        cardViews[id] = nil
        panels.remove(at: index)
        panel.orderOut(nil)
    }

    /// Re-show the most recently dismissed capture.
    func reopenLastClosed() {
        guard let closed = lastClosed else { HUD.show("No closed capture"); return }
        lastClosed = nil
        // The saved file may have been moved/deleted since; only pass a URL that still exists.
        let url = closed.url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        show(closed.image, mode: closed.mode, savedURL: url)
    }

    /// Dismiss a card and reconcile hover/focus against the pointer's real position afterward.
    private func remove(_ panel: FloatPreviewWindow, animated: Bool) {
        guard let index = panels.firstIndex(of: panel) else { return }
        let id = ObjectIdentifier(panel)
        cancelTimer(for: panel)
        hoveredPanels.remove(id)
        if let info = cardInfo[id] { lastClosed = info }
        cardInfo[id] = nil
        cardViews[id] = nil
        panels.remove(at: index)

        if animated {
            panel.order(.below, relativeTo: 0)   // don't obscure survivors sliding into its slot
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
        } else {
            panel.orderOut(nil)
        }

        if panels.isEmpty { removeKeyMonitor() }
        // Reconcile hover first (it may makeKeyAndOrderFront a survivor, which can cancel an in-flight
        // frame animation), THEN run the slide so the remaining cards reliably animate down.
        reconcileHoverUnderPointer()
        repositionAll(animated: true)
    }

    // MARK: Hover / focus

    private func beginHover(_ panel: FloatPreviewWindow) {
        let id = ObjectIdentifier(panel)
        cancelIdleWork()
        let wasIdle = hoveredPanels.isEmpty
        hoveredPanels.insert(id)
        cancelAllTimers()
        if wasIdle, !NSApp.isActive {
            // Remember who had focus so we can hand it back; never record ourselves.
            let front = NSWorkspace.shared.frontmostApplication
            if front != .current { previousApp = front }
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        cardViews[id]?.setHoverVisual(true)
    }

    private func endHover(_ panel: FloatPreviewWindow) {
        hoveredPanels.remove(ObjectIdentifier(panel))
        if hoveredPanels.isEmpty { scheduleIdleTransition() }
    }

    /// After a removal/reposition, a different card may now sit under a stationary pointer (which gets
    /// no synthetic mouseEntered). Re-arm hover on it; otherwise begin the idle transition.
    private func reconcileHoverUnderPointer() {
        if let panel = panelUnderPointer() {
            beginHover(panel)
        } else if hoveredPanels.isEmpty {
            scheduleIdleTransition()
        }
    }

    private func panelUnderPointer() -> FloatPreviewWindow? {
        let p = NSEvent.mouseLocation
        return panels.last { $0.frame.contains(p) }
    }

    /// Debounce the "pointer left the stack" transition so sweeping between adjacent cards doesn't
    /// bounce focus or churn timers.
    private func scheduleIdleTransition() {
        cancelIdleWork()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.hoveredPanels.isEmpty, self.panelUnderPointer() == nil else { return }
                self.restartAllTimers()
                self.restoreFocus()
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func cancelIdleWork() {
        idleWork?.cancel()
        idleWork = nil
    }

    private func restoreFocus() {
        guard let app = previousApp else { return }
        previousApp = nil
        // Only hand focus back if WE still hold it; if the user already switched elsewhere, leave it.
        guard NSApp.isActive, app != .current else { return }
        app.activate()
    }

    // MARK: ⌘W via local key monitor

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent properties are nonisolated; inspect here, touch main-actor state inside.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            let isCmdW = mods == .command && key == "w"
            let isCmdE = mods == .command && key == "e"
            let isCmdC = mods == .command && key == "c"
            let isSpace = mods.isEmpty && event.keyCode == 49
            guard isCmdW || isCmdE || isCmdC || isSpace else { return event }
            var consumed = false
            MainActor.assumeIsolated {
                guard let self else { return }
                // Prefer the card under the pointer; fall back to the top card so a keyboard shortcut
                // still works even if pointer hit-testing missed.
                guard let panel = self.panelUnderPointer() ?? self.panels.last else { return }
                if isCmdW {
                    self.remove(panel, animated: true)
                    consumed = true
                } else if isCmdC {
                    self.cardViews[ObjectIdentifier(panel)]?.onCopy?()
                    consumed = true
                } else if isCmdE {
                    // Open the hovered capture in the editor (the card removes itself first).
                    self.cardViews[ObjectIdentifier(panel)]?.onAnnotate?()
                    consumed = true
                } else if isSpace, let view = self.cardViews[ObjectIdentifier(panel)], view.quickLookURL != nil {
                    panel.makeFirstResponder(view)
                    if let ql = QLPreviewPanel.shared() {
                        if QLPreviewPanel.sharedPreviewPanelExists(), ql.isVisible { ql.orderOut(nil) }
                        else { ql.makeKeyAndOrderFront(nil) }
                    }
                    consumed = true
                }
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
    }

    // MARK: Timers

    private func startTimer(for panel: FloatPreviewWindow) {
        cancelTimer(for: panel)
        let timer = Timer.scheduledTimer(withTimeInterval: autoDismissDelay, repeats: false) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel else { return }
                self.remove(panel, animated: true)
            }
        }
        timers[ObjectIdentifier(panel)] = timer
    }

    private func cancelTimer(for panel: FloatPreviewWindow) {
        let id = ObjectIdentifier(panel)
        timers[id]?.invalidate()
        timers[id] = nil
    }

    private func cancelAllTimers() {
        for timer in timers.values { timer.invalidate() }
        timers.removeAll()
    }

    private func ensureTimersIfIdle() {
        guard hoveredPanels.isEmpty else { return }
        for panel in panels where timers[ObjectIdentifier(panel)] == nil { startTimer(for: panel) }
    }

    private func restartAllTimers() {
        cancelAllTimers()
        for panel in panels { startTimer(for: panel) }
    }

    // MARK: Geometry

    private static func screen(for image: CapturedImage) -> NSScreen {
        if let id = image.displayID, let match = NSScreen.screens.first(where: { $0.displayID == id }) {
            return match
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
