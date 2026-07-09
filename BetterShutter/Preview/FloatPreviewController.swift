import AppKit
import Quartz

extension Notification.Name {
    /// Posted when a Quick Access layout preference (card size or screen side) changes, so any
    /// on-screen cards restack live.
    static let quickAccessSizeChanged = Notification.Name("quickAccessSizeChanged")
}

/// The post-capture quick-access overlay: captures park in the bottom-right corner of the capture's
/// screen and stack as a column of cards (newest nearest the corner). Each card auto-dismisses after
/// a delay unless the pointer is over the stack. While the pointer is over the stack the app takes
/// focus so ⌘W (via a local key monitor) dismisses the card under the pointer; focus returns to the
/// previously-active app once the pointer truly leaves the stack.
@MainActor
final class FloatPreviewController {

    private var panels: [FloatPreviewWindow] = []
    private var cardViews: [ObjectIdentifier: FloatPreviewView] = [:]
    private var cardInfo: [ObjectIdentifier: (image: CapturedImage, mode: CaptureMode, url: URL?, videoURL: URL?)] = [:]
    private var timers: [ObjectIdentifier: Timer] = [:]
    /// A recording can be hundreds of MB. Keep one cancellable save per card so repeated clicks do
    /// not start concurrent full-file copies and removing the card does not leave owned work behind.
    private var saveTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var hoveredPanels: Set<ObjectIdentifier> = []
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var anchorScreen: NSScreen?
    private var idleWork: DispatchWorkItem?
    /// The most recently dismissed capture, for "Restore Closed Quick Access".
    private var lastClosed: (image: CapturedImage, mode: CaptureMode, url: URL?, videoURL: URL?)?

    var onAnnotate: ((CapturedImage, CaptureMode) -> Void)?
    var onBeautify: ((CapturedImage, CaptureMode) -> Void)?
    /// Open the video editor on a recording card's file.
    var onEditVideo: ((URL) -> Void)?

    private let autoDismissDelay: TimeInterval = 8
    private let hardCardCap = 5
    private let spacing: CGFloat = 12
    private let margin: CGFloat = 20

    init() {
        // The controller lives for the whole app session, so the observer never needs removing.
        NotificationCenter.default.addObserver(
            forName: .quickAccessSizeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyCardSize() }
        }
    }

    /// Apply the current Quick Access layout prefs (card size + screen side) to on-screen cards, then
    /// re-stack. Every card is set to its FINAL size+origin in one snapped `setFrame` — resizing via
    /// `setContentSize` first would anchor the bottom-left corner and drift the card out of position,
    /// and animating the origin afterward risks being stranded (a key card cancels the animation).
    private func applyCardSize() {
        guard !panels.isEmpty else { return }
        let size = FloatPreviewView.cardSize

        // Overflow-evict against the NEW height (larger cards may no longer all fit).
        let available = anchorVisibleFrame().height - 2 * margin
        func stacked(_ count: Int) -> CGFloat { CGFloat(count) * size.height + CGFloat(count - 1) * spacing }
        while panels.count > 1, panels.count > hardCardCap || stacked(panels.count) > available,
              let oldest = panels.first {
            evict(oldest)
        }

        let visible = anchorVisibleFrame()
        let side = Preferences.quickAccessSide
        var y = visible.minY + margin
        for panel in panels {
            let x = side == .left ? visible.minX + margin : visible.maxX - margin - size.width
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            panel.invalidateShadow()                 // shadow keeps the old bounds otherwise
            panel.contentView?.needsDisplay = true   // redraw the screenshot crisp at the new size
            y += size.height + spacing
        }
    }

    func show(_ image: CapturedImage, mode: CaptureMode, savedURL: URL?, videoURL: URL? = nil) {
        if panels.isEmpty { anchorScreen = Self.screen(for: image) }

        let cardSize = FloatPreviewView.cardSize(for: image.pixelSize)
        let view = FloatPreviewView(image: image, mode: mode, savedURL: savedURL, videoURL: videoURL)
        view.autoresizingMask = [.width, .height]

        // The card is the screenshot itself (full-bleed); no glass chrome behind it.
        let panel = FloatPreviewWindow(size: cardSize)
        view.frame = NSRect(origin: .zero, size: cardSize)
        panel.contentView = view
        let id = ObjectIdentifier(panel)

        if let videoURL {
            // Recording card: every action targets the movie/GIF file, not the thumbnail frame.
            view.onCopy = { [weak view] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([videoURL as NSURL])
                view?.showCopyFeedback()
            }
            // Only offered when the recording landed in the unsaved-recordings scratch folder
            // (After-Capture Save off). The copy runs off the main thread — recordings can be
            // hundreds of MB — then the card flips to its saved state so a second click reveals
            // instead of writing "(2)" duplicates.
            view.onSave = { [weak self, weak view] in
                guard let self, self.saveTasks[id] == nil else { return }
                let dir = Preferences.saveDirectory
                let task = Task { [weak self, weak view] in
                    let dest = try? await PreviewRecordingSaver.copy(videoURL, to: dir)
                    guard !Task.isCancelled, let self else { return }
                    self.saveTasks[id] = nil
                    guard let dest else { HUD.show("Save failed"); return }
                    guard self.cardInfo[id] != nil else { return }
                    self.cardInfo[id]?.url = dest
                    view?.markSaved(dest)
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
                self.saveTasks[id] = task
            }
            // The trim window can't decode GIF; a GIF card shows no Edit affordance and ⌘E no-ops.
            if videoURL.pathExtension.lowercased() != "gif" {
                view.onAnnotate = { [weak self, weak panel] in
                    if let panel { self?.remove(panel, animated: false) }
                    self?.onEditVideo?(videoURL)
                }
            }
            view.onShare = { [weak view] in
                guard let view else { return }
                let picker = NSSharingServicePicker(items: [videoURL])
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minX)
            }
            view.onUpload = { CloudUploadService.uploadFile(videoURL) }
        } else {
            view.onCopy = { [weak view] in PasteboardWriter.copy(image.cgImage); view?.showCopyFeedback() }
            view.onSave = { [weak self] in
                guard let self, self.saveTasks[id] == nil else { return }
                let task = Task { [weak self] in
                    _ = try? await FileSaver.saveAsync(image.cgImage, mode: mode)
                    guard !Task.isCancelled else { return }
                    self?.saveTasks[id] = nil
                }
                self.saveTasks[id] = task
            }
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
            view.onUpload = { CloudUploadService.upload(image.cgImage) }
        }
        view.onClose = { [weak self, weak panel] in if let panel { self?.remove(panel, animated: true) } }
        view.onHoverChange = { [weak self, weak panel] hovered in
            guard let self, let panel else { return }
            if hovered { self.beginHover(panel) } else { self.endHover(panel) }
        }

        installKeyMonitorIfNeeded()
        panels.append(panel)
        cardViews[id] = view
        cardInfo[id] = (image, mode, savedURL, videoURL)

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
        repositionAll()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        ensureTimersIfIdle()
    }

    /// Dismiss every card (e.g. on quit).
    func dismissAll() {
        cancelIdleWork()
        cancelAllSaveTasks()
        for view in cardViews.values { view.relinquishQuickLookIfOwned() }
        for panel in panels { cancelTimer(for: panel); panel.close() }
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
        let side = Preferences.quickAccessSide
        for panel in panels {                          // oldest (first) at the corner, newest on top
            // Anchor per card to the chosen edge (portrait cards are narrower, so use each card's width).
            let x = side == .left
                ? visible.minX + margin
                : visible.maxX - margin - panel.frame.width
            result[ObjectIdentifier(panel)] = CGPoint(x: x, y: y)
            y += panel.frame.height + spacing
        }
        return result
    }

    /// Move every card to its slot. Positions are committed synchronously (a snap), never through
    /// `animator().setFrameOrigin`. An in-flight window-frame animation is silently cancelled the
    /// moment the window is made key — which happens constantly here, because a card sliding under the
    /// stationary pointer fires `mouseEntered` → `beginHover` → `makeKeyAndOrderFront`. That stranded
    /// the card mid-slide (the gap never closed, and later cards stacked onto the misplaced pile). A
    /// snapped frame has no animation to strand, so the column is always exactly laid out. The per-card
    /// alpha fades (in `show`/`remove`) are separate windows' opacity and are unaffected.
    private func repositionAll() {
        let origins = layout()
        for panel in panels {
            guard let target = origins[ObjectIdentifier(panel)] else { continue }
            panel.setFrameOrigin(target)
        }
    }

    /// Tear down a card with no hover/focus reconciliation (used for overflow eviction).
    private func evict(_ panel: FloatPreviewWindow) {
        guard let index = panels.firstIndex(of: panel) else { return }
        let id = ObjectIdentifier(panel)
        cancelTimer(for: panel)
        cancelSaveTask(for: id)
        hoveredPanels.remove(id)
        // Overflow eviction is not a user close — don't overwrite the restore target.
        cardInfo[id] = nil
        cardViews[id]?.relinquishQuickLookIfOwned()
        cardViews[id] = nil
        panels.remove(at: index)
        panel.close()
    }

    /// Re-show the most recently dismissed capture.
    func reopenLastClosed() {
        guard let closed = lastClosed else { HUD.show("No closed capture"); return }
        lastClosed = nil
        // The saved file may have been moved/deleted since; only pass a URL that still exists.
        let url = closed.url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        // A video card is pointless without its file — restore it as a plain thumbnail card then.
        let videoURL = closed.videoURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        show(closed.image, mode: closed.mode, savedURL: url, videoURL: videoURL)
    }

    /// Dismiss a card and reconcile hover/focus against the pointer's real position afterward.
    private func remove(_ panel: FloatPreviewWindow, animated: Bool) {
        guard let index = panels.firstIndex(of: panel) else { return }
        let id = ObjectIdentifier(panel)
        cancelTimer(for: panel)
        cancelSaveTask(for: id)
        hoveredPanels.remove(id)
        if let info = cardInfo[id] { lastClosed = info }
        cardInfo[id] = nil
        cardViews[id]?.relinquishQuickLookIfOwned()
        cardViews[id] = nil
        panels.remove(at: index)

        if animated {
            panel.order(.below, relativeTo: 0)   // don't obscure survivors sliding into its slot
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { panel.close() } })
        } else {
            panel.close()
        }

        if panels.isEmpty { removeKeyMonitor() }
        reconcileHoverUnderPointer()
        repositionAll()   // survivors snap into place; positions are never left mid-animation
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

    private func cancelSaveTask(for id: ObjectIdentifier) {
        saveTasks.removeValue(forKey: id)?.cancel()
    }

    private func cancelAllSaveTasks() {
        for task in saveTasks.values { task.cancel() }
        saveTasks.removeAll()
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
