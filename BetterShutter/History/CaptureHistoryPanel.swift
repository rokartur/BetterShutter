import AppKit
import AVFoundation
import ImageIO
import Quartz

/// Wraps a CGImage so it can cross the detached-task → main-actor boundary (CGImage is immutable).
private struct ThumbBox: @unchecked Sendable { let cg: CGImage }

/// Type filter for the Capture History bar (mirrors the All / Screenshots / Videos / GIFs / OCR
/// pills). The OCR tab shows recognized-text history from the keychain store, not files.
private enum HistoryFilter: CaseIterable {
    case all, screenshots, videos, gifs, ocr

    var title: String {
        switch self {
        case .all: return "All"
        case .screenshots: return "Screenshots"
        case .videos: return "Videos"
        case .gifs: return "GIFs"
        case .ocr: return "OCR"
        }
    }

    func matches(_ kind: HistoryKind) -> Bool {
        switch self {
        case .all: return true
        case .screenshots: return kind == .image
        case .videos: return kind == .video
        case .gifs: return kind == .gif
        case .ocr: return false   // file cards never show on the OCR tab
        }
    }
}

private nonisolated enum HistoryKind: Sendable {
    case image, video, gif

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "webp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    init?(extension ext: String) {
        let e = ext.lowercased()
        if e == "gif" { self = .gif }
        else if Self.imageExtensions.contains(e) { self = .image }
        else if Self.videoExtensions.contains(e) { self = .video }
        else { return nil }
    }

    var badgeSymbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "video"
        case .gif: return "square.stack.3d.forward.dottedline"
        }
    }
}

private nonisolated struct HistoryEntry: Sendable {
    let url: URL
    let date: Date
    let kind: HistoryKind
}

/// A top-of-screen glass bar listing recent captures (screenshots, recordings, GIFs) read from the
/// save folder, filtered by type and by the configured retention window. Click a thumbnail to select
/// it, then Restore to reopen it; right-click for more actions. Replaces the old Recent submenu and
/// the Browse Captures window.
@MainActor
final class CaptureHistoryPanel: NSObject {
    static let shared = CaptureHistoryPanel()

    private var panel: NSPanel?
    private let filterControl = NSSegmentedControl()
    private let searchField = NSSearchField()
    private var searchQuery = ""
    private let cardStack = NSStackView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No captures yet")

    private var filter: HistoryFilter = .all
    private var entries: [HistoryEntry] = []
    private var ocrEntries: [OCRHistoryEntry] = []
    private var selected: URL?
    private var clickMonitor: Any?
    private var thumbCache: [URL: NSImage] = [:]
    /// OCR cards are built lazily, first time the OCR tab is shown (50 wrapping labels are not free).
    private var ocrCardsBuilt = false
    /// Filename → OCR'd text of archived screenshots, so search matches image *content* too.
    private var searchIndex: [String: String] = [:]
    private var indexingTask: Task<Void, Never>?

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        if panel == nil { build() }
        reload()   // async — the bar opens instantly with the previous content, then refreshes
        position()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installClickMonitor()
    }

    func close() {
        removeClickMonitor()
        panel?.orderOut(nil)
    }

    // MARK: Build

    private func build() {
        let size = panelSize()
        let panel = HistoryPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false   // fixed position — no dragging
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        panel.previewItems = { [weak self] in self?.shownEntries().map { $0.url } ?? [] }
        panel.previewStartIndex = { [weak self] in self?.selectedIndex() ?? 0 }

        // Big, soft corners — extra large on macOS 26's Liquid Glass.
        let radius: CGFloat = { if #available(macOS 26.0, *) { return 34 } else { return 24 } }()
        let glass = GlassPanelView(cornerRadius: radius)
        glass.frame = NSRect(origin: .zero, size: size)
        glass.autoresizingMask = [.width, .height]
        let content = glass.contentView

        // Centered filter pills as a native segmented control — Liquid Glass capsule on Tahoe.
        filterControl.segmentCount = HistoryFilter.allCases.count
        filterControl.trackingMode = .selectOne
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))
        if #available(macOS 26.0, *) {
            filterControl.segmentDistribution = .fillEqually
        }
        for (i, f) in HistoryFilter.allCases.enumerated() {
            filterControl.setLabel(f.title, forSegment: i)
        }
        filterControl.selectedSegment = 0
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(filterControl)

        let close = GlassIconButton.make(symbol: "xmark", tooltip: "Close",
                                         target: self, action: #selector(closeTapped),
                                         pointSize: 12, standalone: true)
        close.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(close)

        // Horizontal scroller of capture cards.
        cardStack.orientation = .horizontal
        cardStack.spacing = 16
        cardStack.alignment = .top
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardStack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.documentView = cardStack
        scroll.automaticallyAdjustsContentInsets = false

        content.addSubview(scroll)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        searchField.placeholderString = "Search names & text"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchField)

        NSLayoutConstraint.activate([
            filterControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            filterControl.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            searchField.centerYAnchor.constraint(equalTo: filterControl.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            searchField.widthAnchor.constraint(equalToConstant: 200),

            close.centerYAnchor.constraint(equalTo: filterControl.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            close.widthAnchor.constraint(equalToConstant: 26),
            close.heightAnchor.constraint(equalToConstant: 26),

            scroll.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),

            cardStack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        panel.contentView = glass
        self.panel = panel
        syncFilter()
    }

    private func panelSize() -> NSSize {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSSize(width: min(visible.width - 80, 1240), height: 232)
    }

    private func position() {
        guard let panel, let visible = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 12
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    // MARK: Data

    /// Refresh off the main thread: prune, directory listing, date reads, and the keychain fetch
    /// all happen in a detached task, then the UI applies the result — opening the bar never
    /// blocks on file I/O.
    private func reload() {
        let retention = Preferences.captureHistoryRetention
        Task.detached(priority: .userInitiated) { [weak self] in
            CaptureHistoryStore.prune(retention: retention)
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let files = (try? FileManager.default.contentsOfDirectory(
                at: CaptureHistoryStore.directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []
            let cutoff = retention.maxAge.map { Date().addingTimeInterval(-$0) }
            var list = files.compactMap { url -> HistoryEntry? in
                guard let kind = HistoryKind(extension: url.pathExtension) else { return nil }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = values?.contentModificationDate ?? .distantPast
                if let cutoff, date < cutoff { return nil }
                return HistoryEntry(url: url, date: date, kind: kind)
            }
            list.sort { $0.date > $1.date }
            // Bound the work so a huge archive never stalls the bar.
            if list.count > 80 { list = Array(list.prefix(80)) }
            let ocr = OCRHistoryStore.all()
            let index = HistorySearchIndex.load()
            await MainActor.run { self?.apply(entries: list, ocr: ocr, index: index) }
        }
    }

    /// Apply a freshly loaded snapshot. Cards are only torn down and rebuilt when the content
    /// actually changed — reopening the bar with the same history reuses every view and just
    /// refreshes captions and visibility.
    private func apply(entries newEntries: [HistoryEntry], ocr: [OCRHistoryEntry], index: [String: String]) {
        let sameContent = newEntries.map(\.url) == entries.map(\.url) && ocr == ocrEntries
        entries = newEntries
        ocrEntries = ocr

        // Evict cached thumbnails for files no longer listed (deleted / retention-pruned) — the
        // panel is a singleton, so without this the cache grows for the app's whole lifetime.
        let live = Set(entries.map(\.url))
        thumbCache = thumbCache.filter { live.contains($0.key) }

        // Adopt the persisted OCR index, dropping entries whose files are gone, then scan whatever
        // is new in the background so content search keeps getting better as the user works.
        let liveNames = Set(entries.map { $0.url.lastPathComponent })
        let pruned = index.filter { liveNames.contains($0.key) }
        searchIndex = pruned
        if pruned.count != index.count {
            Task.detached(priority: .utility) { HistorySearchIndex.save(pruned) }
        }
        indexMissingEntries()

        if let selected, !entries.contains(where: { $0.url == selected }) { self.selected = nil }
        if selected == nil, let first = shownEntries().first { selected = first.url }

        if sameContent, ocrCardsBuilt || shownOCRIndices().isEmpty {
            refreshCaptions()
            applyFilterToCards()
            if let selected { select(selected) }
        } else {
            rebuildCards()
        }
    }

    /// Update the "… ago" captions in place (reused cards would otherwise show stale times).
    private func refreshCaptions() {
        let now = Date()
        let dates = Dictionary(entries.map { ($0.url, $0.date) }, uniquingKeysWith: { a, _ in a })
        for card in cardStack.arrangedSubviews {
            switch card {
            case let file as HistoryCard:
                if let date = dates[file.url] {
                    file.setTimeText(Self.relative.localizedString(for: date, relativeTo: now))
                }
            case let ocr as OCRTextCard:
                if ocrEntries.indices.contains(ocr.index) {
                    ocr.setTimeText(Self.relative.localizedString(for: ocrEntries[ocr.index].date, relativeTo: now))
                }
            default: break
            }
        }
    }

    /// Scan archived screenshots that aren't in the OCR index yet, one at a time in the background.
    /// Each result lands in the live index (and on disk), so a content search improves as it runs.
    private func indexMissingEntries() {
        guard indexingTask == nil else { return }
        let missing = entries
            .filter { $0.kind == .image && searchIndex[$0.url.lastPathComponent] == nil }
            .map(\.url)
        guard !missing.isEmpty else { return }
        indexingTask = Task { [weak self] in
            for url in missing {
                let text = await HistorySearchIndex.recognizeText(at: url)
                guard let self else { return }
                self.searchIndex[url.lastPathComponent] = text
                // Refresh live results while the user is mid-search.
                if !self.searchQuery.isEmpty, !text.isEmpty { self.applyFilterToCards() }
            }
            guard let self else { return }
            let snapshot = self.searchIndex
            Task.detached(priority: .utility) { HistorySearchIndex.save(snapshot) }
            self.indexingTask = nil
            self.indexMissingEntries()   // catch files that arrived while this batch ran
        }
    }

    private func matchesSearch(_ entry: HistoryEntry) -> Bool {
        if searchQuery.isEmpty { return true }
        if entry.url.lastPathComponent.localizedCaseInsensitiveContains(searchQuery) { return true }
        if let text = searchIndex[entry.url.lastPathComponent],
           text.localizedCaseInsensitiveContains(searchQuery) { return true }
        return false
    }

    private func shownEntries() -> [HistoryEntry] {
        entries.filter { filter.matches($0.kind) && matchesSearch($0) }
    }

    /// OCR entries surface on their own tab always, and on the All tab while a search is active —
    /// a content search should pull matching recognized-text results in next to the files.
    private func ocrVisible() -> Bool {
        filter == .ocr || (filter == .all && !searchQuery.isEmpty)
    }

    /// Indices into `ocrEntries` currently visible (search matches the recognized text).
    private func shownOCRIndices() -> Set<Int> {
        guard ocrVisible() else { return [] }
        return Set(ocrEntries.indices.filter {
            searchQuery.isEmpty || ocrEntries[$0].text.localizedCaseInsensitiveContains(searchQuery)
        })
    }

    private func updateEmptyLabel(anyShown: Bool) {
        emptyLabel.isHidden = anyShown
        if filter == .ocr {
            emptyLabel.stringValue = Preferences.ocrHistoryEnabled
                ? (ocrEntries.isEmpty ? "No OCR history yet" : "Nothing in this filter")
                : "OCR history is off (Settings ▸ Capture)"
        } else {
            emptyLabel.stringValue = entries.isEmpty ? "No captures yet" : "Nothing in this filter"
        }
    }

    /// Full rebuild (reload path): one card per entry, with the current filter applied via
    /// `isHidden`. Search/filter changes only toggle visibility — see `applyFilterToCards()`.
    private func rebuildCards() {
        cardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shown = shownEntries()
        let shownURLs = Set(shown.map(\.url))
        let shownOCR = shownOCRIndices()
        updateEmptyLabel(anyShown: !shown.isEmpty || !shownOCR.isEmpty)

        for entry in entries {
            let card = HistoryCard(
                url: entry.url,
                timeText: Self.relative.localizedString(for: entry.date, relativeTo: Date()),
                badge: entry.kind.badgeSymbol,
                thumbnail: thumbCache[entry.url]   // cached if known; otherwise a placeholder is shown
            )
            card.isHidden = !shownURLs.contains(entry.url)
            card.isSelected = (entry.url == selected)
            card.onSelect = { [weak self] in self?.select(entry.url) }
            card.onRestore = { [weak self] in self?.restore(entry.url) }
            card.onMenu = { [weak self] event in self?.showContextMenu(for: entry.url, event: event, in: card) }
            cardStack.addArrangedSubview(card)
        }

        // Recognized-text cards trail the file cards. They are only materialized once OCR entries
        // can actually show — no point building dozens of text views the user may never look at.
        ocrCardsBuilt = ocrVisible()
        if ocrCardsBuilt {
            for (index, entry) in ocrEntries.enumerated() {
                let card = OCRTextCard(
                    index: index,
                    text: entry.text,
                    timeText: Self.relative.localizedString(for: entry.date, relativeTo: Date())
                )
                card.isHidden = !shownOCR.contains(index)
                card.onRestore = { [weak self] in self?.restoreOCR(index) }
                card.onMenu = { [weak self] event in self?.showOCRContextMenu(index: index, event: event, in: card) }
                cardStack.addArrangedSubview(card)
            }
        }
        loadThumbnails(for: shown)
    }

    /// Toggle existing cards instead of tearing down and rebuilding ≤80 views (layers, tracking
    /// areas, shadows) on every search keystroke or filter tap. NSStackView detaches hidden
    /// arranged subviews from layout, so order and spacing are preserved.
    private func applyFilterToCards() {
        let shown = shownEntries()
        let shownURLs = Set(shown.map(\.url))
        let shownOCR = shownOCRIndices()
        for card in cardStack.arrangedSubviews {
            switch card {
            case let file as HistoryCard: file.isHidden = !shownURLs.contains(file.url)
            case let ocr as OCRTextCard: ocr.isHidden = !shownOCR.contains(ocr.index)
            default: break
            }
        }
        updateEmptyLabel(anyShown: !shown.isEmpty || !shownOCR.isEmpty)
        loadThumbnails(for: shown)   // decode thumbnails only for newly revealed cards
    }

    /// Decode downscaled thumbnails off the main thread and drop them into their cards as they finish,
    /// so the bar opens instantly instead of blocking on full-resolution image/video decodes.
    private func loadThumbnails(for shown: [HistoryEntry]) {
        let scale = panel?.backingScaleFactor ?? 2
        // Exactly the tile size in device pixels: the bitmap fills the card edge-to-edge (clean
        // rounded corners) and every cached thumbnail has the same small, fixed footprint.
        let pixelSize = CGSize(width: HistoryCard.thumbWidth * scale, height: HistoryCard.thumbHeight * scale)
        for entry in shown where thumbCache[entry.url] == nil {
            let url = entry.url
            let kind = entry.kind
            Task.detached(priority: .userInitiated) {
                guard let cg = Self.makeThumbnail(url: url, kind: kind, pixelSize: pixelSize) else { return }
                let box = ThumbBox(cg: cg)
                await MainActor.run { [weak self] in self?.applyThumbnail(box.cg, for: url) }
            }
        }
    }

    private func applyThumbnail(_ cg: CGImage, for url: URL) {
        let image = NSImage(cgImage: cg, size: NSSize(width: HistoryCard.thumbWidth, height: HistoryCard.thumbHeight))
        thumbCache[url] = image
        for case let card as HistoryCard in cardStack.arrangedSubviews where card.url == url {
            card.setThumbnail(image)
        }
    }

    private func select(_ url: URL) {
        selected = url
        for case let card as HistoryCard in cardStack.arrangedSubviews {
            card.isSelected = (card.url == url)
        }
    }

    // MARK: Keyboard navigation + preview

    private func selectedIndex() -> Int {
        let shown = shownEntries()
        if let selected, let i = shown.firstIndex(where: { $0.url == selected }) { return i }
        return 0
    }

    /// Handle arrows / space / return / esc. Returns true when consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: moveSelection(by: -1); return true   // ←
        case 124: moveSelection(by: 1); return true    // →
        case 49: togglePreview(); return true          // space → Quick Look
        case 36, 76: if let selected { restore(selected) }; return true   // return → restore
        case 53: close(); return true                  // esc
        default: return false
        }
    }

    private func moveSelection(by delta: Int) {
        let shown = shownEntries()
        guard !shown.isEmpty else { return }
        if selected == nil { select(shown[0].url); scrollToSelected(); syncPreview(); return }
        let next = min(max(selectedIndex() + delta, 0), shown.count - 1)
        select(shown[next].url)
        scrollToSelected()
        syncPreview()
    }

    private func scrollToSelected() {
        guard let selected else { return }
        for case let card as HistoryCard in cardStack.arrangedSubviews where card.url == selected {
            card.scrollToVisible(card.bounds.insetBy(dx: -28, dy: 0))
        }
    }

    private func togglePreview() {
        guard let ql = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && ql.isVisible {
            ql.orderOut(nil)
        } else {
            ql.makeKeyAndOrderFront(nil)
        }
    }

    /// Keep an open Quick Look in step with the keyboard selection.
    private func syncPreview() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let ql = QLPreviewPanel.shared(), ql.isVisible else { return }
        ql.currentPreviewItemIndex = selectedIndex()
        ql.reloadData()
    }

    // MARK: Thumbnails

    /// Nonisolated so it can run in a detached task. Uses ImageIO's thumbnail path (decodes only a
    /// downscaled bitmap, never the full image) for stills/GIFs, and a single frame for videos,
    /// then center-crops to exactly the tile's pixel size.
    private nonisolated static func makeThumbnail(url: URL, kind: HistoryKind, pixelSize: CGSize) -> CGImage? {
        let decoded: CGImage?
        switch kind {
        case .image, .gif:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(pixelSize.width, pixelSize.height),
            ]
            decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = pixelSize
            decoded = try? generator.copyCGImage(at: CMTime(value: 1, timescale: 4), actualTime: nil)
        }
        guard let decoded else { return nil }
        return fillCrop(decoded, to: pixelSize)
    }

    /// Scale-and-center-crop to exactly `size` (aspect fill). The tile's rounded-corner mask then
    /// clips real pixels on every edge — aspect-fit gaps were what made the card corners look
    /// mismatched against the border.
    private nonisolated static func fillCrop(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return image }
        if image.width == w && image.height == h { return image }
        let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let dw = CGFloat(image.width) * scale
        let dh = CGFloat(image.height) * scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (size.width - dw) / 2, y: (size.height - dh) / 2, width: dw, height: dh))
        return ctx.makeImage() ?? image
    }

    // MARK: Actions

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshAfterFilterChange()
    }

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard HistoryFilter.allCases.indices.contains(index) else { return }
        filter = HistoryFilter.allCases[index]
        refreshAfterFilterChange()
    }

    /// Cheap visibility pass, unless OCR entries just became visible for the first time — their
    /// cards are lazy and must be materialized with a rebuild.
    private func refreshAfterFilterChange() {
        if !ocrCardsBuilt, !shownOCRIndices().isEmpty {
            rebuildCards()
        } else {
            applyFilterToCards()
        }
    }

    private func syncFilter() {
        filterControl.selectedSegment = HistoryFilter.allCases.firstIndex(of: filter) ?? 0
    }

    @objc private func closeTapped() { close() }

    /// Restore a capture: images come back as a quick-access card (float preview); videos and GIFs
    /// open in their default app.
    private func restore(_ url: URL) {
        guard let kind = HistoryKind(extension: url.pathExtension) else { return }
        switch kind {
        case .video, .gif:
            NSWorkspace.shared.open(url)
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            CaptureCoordinator.shared.reopenPreview(
                CapturedImage(cgImage: cg, scale: 1, displayID: nil), mode: .region, savedURL: url)
        }
        close()
    }

    private func showContextMenu(for url: URL, event: NSEvent, in view: NSView) {
        select(url)
        let menu = NSMenu()
        for (title, sel) in [
            ("Restore", #selector(menuRestore)),
            ("Reveal in Finder", #selector(menuReveal)),
            ("Copy", #selector(menuCopy)),
            ("Upload & Copy Link", #selector(menuUpload)),
            ("Share…", #selector(menuShare)),
            ("Delete", #selector(menuDelete)),
        ] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func menuRestore() { if let selected { restore(selected) } }
    @objc private func menuReveal() { if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected]) } }
    @objc private func menuUpload() { if let selected { CloudUploadService.uploadFile(selected) } }

    @objc private func menuCopy() {
        guard let selected, let kind = HistoryKind(extension: selected.pathExtension) else { return }
        switch kind {
        case .image, .gif:
            if let source = CGImageSourceCreateWithURL(selected as CFURL, nil),
               let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                PasteboardWriter.copy(cg)   // PNG + TIFF — every paste target understands one
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([selected as NSURL])
            }
        case .video:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([selected as NSURL])
        }
        HUD.show("Copied")
    }

    @objc private func menuShare() {
        guard let selected else { return }
        let anchor = panel?.contentView ?? NSView()
        let picker = NSSharingServicePicker(items: [selected])
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    // MARK: OCR entries

    /// Open a recognized-text entry in the OCR result window.
    private func restoreOCR(_ index: Int) {
        guard ocrEntries.indices.contains(index) else { return }
        OCRResultWindowController.shared.show(text: ocrEntries[index].text, barcodes: [])
        close()
    }

    private func showOCRContextMenu(index: Int, event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        for (title, sel) in [
            ("Open", #selector(ocrMenuOpen(_:))),
            ("Copy Text", #selector(ocrMenuCopy(_:))),
            ("Delete", #selector(ocrMenuDelete(_:))),
            ("Clear OCR History", #selector(ocrMenuClear)),
        ] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func ocrMenuOpen(_ sender: NSMenuItem) { restoreOCR(sender.tag) }

    @objc private func ocrMenuCopy(_ sender: NSMenuItem) {
        guard ocrEntries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ocrEntries[sender.tag].text, forType: .string)
        HUD.show("Copied")
    }

    @objc private func ocrMenuDelete(_ sender: NSMenuItem) {
        OCRHistoryStore.remove(at: sender.tag)
        reload()
    }

    @objc private func ocrMenuClear() {
        OCRHistoryStore.clear()
        reload()
    }

    @objc private func menuDelete() {
        guard let selected else { return }
        try? FileManager.default.trashItem(at: selected, resultingItemURL: nil)
        thumbCache[selected] = nil
        self.selected = nil
        reload()
    }

    // MARK: Dismiss-on-outside-click

    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // A click in any other app/window dismisses the bar.
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

/// One capture in the history bar: a rounded thumbnail with a type badge and a "… ago" caption. On
/// hover it lifts and reveals a glass Restore button; the selection draws an accent ring. Every
/// layer-baked color re-resolves with the system appearance so light/dark both look right.
private final class HistoryCard: NSView, NSDraggingSource {
    static let thumbWidth: CGFloat = 176
    static let thumbHeight: CGFloat = 120
    private let corner: CGFloat = 16

    let url: URL
    var onSelect: (() -> Void)?
    var onRestore: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    private var mouseDownPoint: CGPoint?

    private let thumb = NSView()   // shadow host — must NOT mask, or the shadow disappears
    private let clip = NSView()    // rounded clip + border, drawn over the image for crisp corners
    private let imageView = NSImageView()
    private let scrim = CAGradientLayer()
    private let restoreButton = NSButton()
    private let caption = NSTextField(labelWithString: "")
    private let badge = NSView()
    private let badgeIcon = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var hovering = false

    var isSelected = false { didSet { updateState() } }

    init(url: URL, timeText: String, badge symbol: String, thumbnail: NSImage?) {
        self.url = url
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Thumbnail tile: rounded, hairline-bordered, with a soft drop shadow that grows on hover.
        // The shadow lives on `thumb` (unmasked) while `clip` masks the image and draws the border
        // on top of it — one layer doing both would either lose the shadow or leave the image's
        // antialiased edge poking past the border at the corners.
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.wantsLayer = true
        thumb.layer?.shadowColor = NSColor.black.cgColor
        thumb.layer?.shadowOpacity = 0.18
        thumb.layer?.shadowRadius = 6
        thumb.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(thumb)

        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.wantsLayer = true
        clip.layer?.cornerRadius = corner
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1
        thumb.addSubview(clip)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleAxesIndependently   // thumbnails arrive pre-cropped to tile size
        imageView.wantsLayer = true
        imageView.image = thumbnail
        imageView.symbolConfiguration = GlassTokens.symbol(22, .regular)
        if thumbnail == nil {
            imageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            imageView.contentTintColor = .tertiaryLabelColor
            imageView.imageScaling = .scaleNone
        }
        clip.addSubview(imageView)

        // Scrim behind the Restore button for legibility over bright captures.
        scrim.colors = [NSColor.clear.cgColor, GlassTokens.scrimBottom.cgColor]
        scrim.locations = [0.45, 1.0]
        scrim.cornerRadius = corner
        scrim.cornerCurve = .continuous
        scrim.opacity = 0
        imageView.layer?.addSublayer(scrim)

        // Type badge — a small rounded chip.
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        badge.layer?.cornerCurve = .continuous
        badge.layer?.masksToBounds = true
        badgeIcon.translatesAutoresizingMaskIntoConstraints = false
        badgeIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(GlassTokens.symbol(10, .semibold))
        badgeIcon.contentTintColor = .white
        badge.addSubview(badgeIcon)
        thumb.addSubview(badge)

        // Glass Restore button (revealed on hover / selection).
        restoreButton.title = "Restore"
        restoreButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Restore")?
            .withSymbolConfiguration(GlassTokens.symbol(11, .semibold))
        restoreButton.imagePosition = .imageLeading
        restoreButton.controlSize = .regular
        restoreButton.bezelColor = .controlAccentColor
        restoreButton.contentTintColor = .white
        if #available(macOS 26.0, *) { restoreButton.bezelStyle = .glass } else { restoreButton.bezelStyle = .rounded }
        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.alphaValue = 0
        thumb.addSubview(restoreButton)

        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.stringValue = timeText
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        addSubview(caption)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.thumbWidth),

            thumb.topAnchor.constraint(equalTo: topAnchor),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumb.heightAnchor.constraint(equalToConstant: Self.thumbHeight),

            clip.topAnchor.constraint(equalTo: thumb.topAnchor),
            clip.leadingAnchor.constraint(equalTo: thumb.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: thumb.trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: thumb.bottomAnchor),

            imageView.topAnchor.constraint(equalTo: clip.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: clip.bottomAnchor),

            badge.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -7),
            badge.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: -7),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badgeIcon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeIcon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            restoreButton.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            restoreButton.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),

            caption.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 8),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        applyAppearanceColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        scrim.frame = imageView.bounds
        // An explicit shadow path lets Core Animation skip the per-frame offscreen mask pass it
        // otherwise needs to derive the shadow shape — noticeable across up to 80 live cards.
        thumb.layer?.shadowPath = CGPath(roundedRect: thumb.bounds,
                                         cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    func setThumbnail(_ image: NSImage) {
        imageView.image = image
        imageView.contentTintColor = nil
        imageView.imageScaling = .scaleAxesIndependently
    }

    func setTimeText(_ text: String) {
        if caption.stringValue != text { caption.stringValue = text }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        clip.layer?.backgroundColor = GlassTokens.cg(GlassTokens.cardBacking, for: self)
        clip.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : GlassTokens.cg(GlassTokens.hairline, for: self)
        badge.layer?.backgroundColor = GlassTokens.cg(GlassTokens.cardBacking, for: self)
        scrim.colors = [NSColor.clear.cgColor, GlassTokens.cg(GlassTokens.scrimBottom, for: self)]
    }

    private func updateState() {
        let reveal = isSelected || hovering
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            clip.layer?.borderWidth = isSelected ? 2.5 : 1
            clip.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : GlassTokens.cg(GlassTokens.hairline, for: self)
            thumb.layer?.shadowOpacity = hovering ? 0.32 : 0.18
            thumb.layer?.shadowRadius = hovering ? 10 : 6
            restoreButton.animator().alphaValue = reveal ? 1 : 0
            scrim.opacity = reveal ? 1 : 0
            caption.animator().textColor = reveal ? .labelColor : .secondaryLabelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateState() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateState() }

    /// The thumbnail/badge subviews fully cover the card, so without this every mouse event would land
    /// on them and the card's own click / drag / right-click handlers would never fire. Route hits to
    /// the card, except over the revealed Restore button which must stay clickable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if restoreButton.alphaValue > 0.5 {
            let local = restoreButton.convert(point, from: superview)
            if restoreButton.bounds.contains(local) { return restoreButton }
        }
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { onRestore?(); mouseDownPoint = nil; return }
        onSelect?()
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let now = event.locationInWindow
        if hypot(now.x - start.x, now.y - start.y) < 6 { return }   // ignore jitter
        mouseDownPoint = nil
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    /// Drag the real file out — drop targets (text inputs, Finder, chat apps) receive the capture.
    private func beginDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = imageView.image ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        item.setDraggingFrame(thumb.frame, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }

    @objc private func restoreTapped() { onRestore?() }
}

/// One recognized-text (OCR) entry in the history bar: a rounded tile with the text excerpt, a type
/// badge, and a "… ago" caption. Hover reveals an Open button that reopens the entry in the
/// Recognized Text window; right-click offers Copy / Delete / Clear.
private final class OCRTextCard: NSView {
    private let corner: CGFloat = 16

    let index: Int
    var onRestore: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    private let tile = NSView()
    private let excerpt = NSTextField(wrappingLabelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let badge = NSView()
    private let badgeIcon = NSImageView()
    private let openButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var hovering = false

    init(index: Int, text: String, timeText: String) {
        self.index = index
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        tile.layer?.cornerRadius = corner
        tile.layer?.cornerCurve = .continuous
        tile.layer?.borderWidth = 1
        tile.layer?.shadowColor = NSColor.black.cgColor
        tile.layer?.shadowOpacity = 0.18
        tile.layer?.shadowRadius = 6
        tile.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(tile)

        excerpt.translatesAutoresizingMaskIntoConstraints = false
        excerpt.stringValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
        excerpt.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        excerpt.textColor = .labelColor
        excerpt.maximumNumberOfLines = 6
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.cell?.truncatesLastVisibleLine = true
        tile.addSubview(excerpt)

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        badge.layer?.cornerCurve = .continuous
        badge.layer?.masksToBounds = true
        badgeIcon.translatesAutoresizingMaskIntoConstraints = false
        badgeIcon.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(GlassTokens.symbol(10, .semibold))
        badgeIcon.contentTintColor = .white
        badge.addSubview(badgeIcon)
        tile.addSubview(badge)

        openButton.title = "Open"
        openButton.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Open")?
            .withSymbolConfiguration(GlassTokens.symbol(11, .semibold))
        openButton.imagePosition = .imageLeading
        openButton.controlSize = .regular
        openButton.bezelColor = .controlAccentColor
        openButton.contentTintColor = .white
        if #available(macOS 26.0, *) { openButton.bezelStyle = .glass } else { openButton.bezelStyle = .rounded }
        openButton.target = self
        openButton.action = #selector(openTapped)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.alphaValue = 0
        tile.addSubview(openButton)

        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.stringValue = timeText
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        addSubview(caption)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: HistoryCard.thumbWidth),

            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: trailingAnchor),
            tile.heightAnchor.constraint(equalToConstant: HistoryCard.thumbHeight),

            excerpt.topAnchor.constraint(equalTo: tile.topAnchor, constant: 10),
            excerpt.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 10),
            excerpt.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -10),
            excerpt.bottomAnchor.constraint(lessThanOrEqualTo: tile.bottomAnchor, constant: -10),

            badge.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -7),
            badge.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -7),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badgeIcon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeIcon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            openButton.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            openButton.centerYAnchor.constraint(equalTo: tile.centerYAnchor),

            caption.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 8),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        applyAppearanceColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        tile.layer?.shadowPath = CGPath(roundedRect: tile.bounds,
                                        cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        tile.layer?.backgroundColor = GlassTokens.cg(GlassTokens.cardBacking, for: self)
        tile.layer?.borderColor = GlassTokens.cg(GlassTokens.hairline, for: self)
        badge.layer?.backgroundColor = GlassTokens.cg(GlassTokens.cardBacking, for: self)
    }

    private func updateState() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            tile.layer?.shadowOpacity = hovering ? 0.32 : 0.18
            tile.layer?.shadowRadius = hovering ? 10 : 6
            openButton.animator().alphaValue = hovering ? 1 : 0
            caption.animator().textColor = hovering ? .labelColor : .secondaryLabelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateState() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateState() }

    func setTimeText(_ text: String) {
        if caption.stringValue != text { caption.stringValue = text }
    }

    /// Route hits to the card so double-click / right-click land here, except over the revealed
    /// Open button which must stay clickable (subviews otherwise swallow every event).
    override func hitTest(_ point: NSPoint) -> NSView? {
        if openButton.alphaValue > 0.5 {
            let local = openButton.convert(point, from: superview)
            if openButton.bounds.contains(local) { return openButton }
        }
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { onRestore?() }
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }

    @objc private func openTapped() { onRestore?() }
}

/// Borderless glass panel that can become key (so it receives arrow / space / return / esc) and hosts
/// Quick Look for the selected capture.
private final class HistoryPanel: NSPanel, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onKeyDown: ((NSEvent) -> Bool)?
    var previewItems: () -> [URL] = { [] }
    var previewStartIndex: () -> Int = { 0 }
    // Snapshotted when Quick Look opens so the nonisolated data-source reads need no actor hop.
    nonisolated(unsafe) private var urls: [URL] = []

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            urls = previewItems()
            panel.dataSource = self
            panel.delegate = self
            panel.currentPreviewItemIndex = previewStartIndex()
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? (urls[index] as NSURL) : nil
    }
}
