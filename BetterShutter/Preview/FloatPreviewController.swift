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
    private var timers: [ObjectIdentifier: Timer] = [:]
    private var hoveredPanels: Set<ObjectIdentifier> = []
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var anchorScreen: NSScreen?
    private var idleWork: DispatchWorkItem?

    var onAnnotate: ((CapturedImage, CaptureMode) -> Void)?
    var onBeautify: ((CapturedImage, CaptureMode) -> Void)?

    private let autoDismissDelay: TimeInterval = 8
    private let hardCardCap = 5
    private let cardSize = FloatPreviewView.cardSize
    private let spacing: CGFloat = 12
    private let margin: CGFloat = 20

    func show(_ image: CapturedImage, mode: CaptureMode, savedURL: URL?) {
        if panels.isEmpty { anchorScreen = Self.screen(for: image) }

        let view = FloatPreviewView(image: image, mode: mode, savedURL: savedURL)
        let glass = GlassPanelView(cornerRadius: 16)
        glass.frame = NSRect(origin: .zero, size: cardSize)
        view.frame = glass.bounds
        view.autoresizingMask = [.width, .height]
        glass.contentView.addSubview(view)

        let panel = FloatPreviewWindow(size: cardSize)
        panel.contentView = glass
        let id = ObjectIdentifier(panel)

        view.onCopy = { PasteboardWriter.copy(image.cgImage) }
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

        // Evict the oldest cards that no longer fit (height-bounded), before positioning the new one.
        let cap = cardCapacity()
        while panels.count > cap, let oldest = panels.first {
            evict(oldest)
        }

        if let index = panels.firstIndex(of: panel) {
            panel.setFrameOrigin(origin(forIndex: index, count: panels.count))
        }
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
        timers.removeAll()
        hoveredPanels.removeAll()
        removeKeyMonitor()
        restoreFocus()
    }

    // MARK: Stacking

    private func cardCapacity() -> Int {
        let visible = anchorVisibleFrame()
        let per = cardSize.height + spacing
        let fit = Int(((visible.height - 2 * margin + spacing) / per).rounded(.down))
        return max(1, min(hardCardCap, fit))
    }

    private func anchorVisibleFrame() -> CGRect {
        (anchorScreen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
    }

    private func origin(forIndex index: Int, count: Int) -> CGPoint {
        let visible = anchorVisibleFrame()
        let reversed = count - 1 - index            // 0 = newest, sits at the corner
        let x = visible.maxX - margin - cardSize.width
        let y = visible.minY + margin + CGFloat(reversed) * (cardSize.height + spacing)
        return CGPoint(x: x, y: y)
    }

    private func repositionAll(animated: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.22 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (index, panel) in panels.enumerated() {
                let target = origin(forIndex: index, count: panels.count)
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
        cardViews[id] = nil
        panels.remove(at: index)
        panel.orderOut(nil)
    }

    /// Dismiss a card and reconcile hover/focus against the pointer's real position afterward.
    private func remove(_ panel: FloatPreviewWindow, animated: Bool) {
        guard let index = panels.firstIndex(of: panel) else { return }
        let id = ObjectIdentifier(panel)
        cancelTimer(for: panel)
        hoveredPanels.remove(id)
        cardViews[id] = nil
        panels.remove(at: index)

        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
        } else {
            panel.orderOut(nil)
        }

        if panels.isEmpty { removeKeyMonitor() }
        repositionAll(animated: true)
        reconcileHoverUnderPointer()
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
        if app != .current { app.activate() }
    }

    // MARK: ⌘W via local key monitor

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent properties are nonisolated; inspect here, touch main-actor state inside.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCmdW = mods == .command && event.charactersIgnoringModifiers?.lowercased() == "w"
            let isSpace = mods.isEmpty && event.keyCode == 49
            guard isCmdW || isSpace else { return event }
            var consumed = false
            MainActor.assumeIsolated {
                guard let self, let panel = self.panelUnderPointer() else { return }
                if isCmdW {
                    self.remove(panel, animated: true)
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
