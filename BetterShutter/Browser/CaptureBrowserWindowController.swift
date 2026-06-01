import AppKit

/// A persistent, searchable browser over saved captures — the files in the configured save folder.
/// Liquid-glass window with a thumbnail list, live filename search, and open / reveal / copy /
/// delete actions. Snapzy-style "capture history browser", but backed by real files on disk.
@MainActor
final class CaptureBrowserWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = CaptureBrowserWindowController()

    private struct Entry { let url: URL; let date: Date; let size: Int }

    private var window: NSWindow?
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let emptyLabel = NSTextField(labelWithString: "No captures yet")
    private var all: [Entry] = []
    private var shown: [Entry] = []
    private var thumbCache: [URL: NSImage] = [:]

    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff"]

    func show() {
        if window == nil { build() }
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Build

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Captures"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()

        let glass = GlassPanelView(cornerRadius: 0)
        window.contentView = glass
        let content = glass.contentView

        searchField.placeholderString = "Search captures"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchField)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        content.addSubview(scroll)

        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .inset
        table.rowHeight = 64
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.menu = makeContextMenu()
        let column = NSTableColumn(identifier: .init("capture"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        self.window = window
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, sel) in [
            ("Open", #selector(openSelected)),
            ("Reveal in Finder", #selector(revealSelected)),
            ("Copy", #selector(copySelected)),
            ("Delete", #selector(deleteSelected)),
        ] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Data

    private func reload() {
        let directory = Preferences.saveDirectory
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []

        all = files.compactMap { url in
            guard Self.extensions.contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(
                url: url,
                date: values?.contentModificationDate ?? .distantPast,
                size: values?.fileSize ?? 0
            )
        }.sorted { $0.date > $1.date }

        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = query.isEmpty ? all : all.filter { $0.url.lastPathComponent.lowercased().contains(query) }
        emptyLabel.isHidden = !shown.isEmpty
        emptyLabel.stringValue = all.isEmpty ? "No captures yet" : "No matches"
        table.reloadData()
    }

    @objc private func searchChanged() { applyFilter() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? BrowserCell) ?? BrowserCell(id: id)
        let entry = shown[row]
        cell.configure(filename: entry.url.lastPathComponent, date: entry.date, size: entry.size,
                       thumbnail: thumbnail(for: entry.url))
        return cell
    }

    private func thumbnail(for url: URL) -> NSImage? {
        if let cached = thumbCache[url] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let maxSide: CGFloat = 96
        let scale = min(maxSide / max(image.size.width, 1), maxSide / max(image.size.height, 1), 1)
        let target = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        thumb.unlockFocus()
        thumbCache[url] = thumb
        return thumb
    }

    // MARK: Actions

    private var selectedURL: URL? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard shown.indices.contains(row) else { return nil }
        return shown[row].url
    }

    @objc private func openSelected() {
        guard let url = selectedURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealSelected() {
        guard let url = selectedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copySelected() {
        guard let url = selectedURL, let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc private func deleteSelected() {
        guard let url = selectedURL else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        thumbCache[url] = nil
        reload()
    }

    func windowWillClose(_ notification: Notification) {
        thumbCache.removeAll()
    }
}

/// One row: thumbnail + filename + date/size.
private final class BrowserCell: NSTableCellView {
    private let thumb = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id

        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.masksToBounds = true
        addSubview(thumb)

        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detail)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 84),
            thumb.heightAnchor.constraint(equalToConstant: 52),

            name.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            name.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 4),

            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(filename: String, date: Date, size: Int, thumbnail: NSImage?) {
        name.stringValue = filename
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        detail.stringValue = "\(Self.formatter.string(from: date)) · \(sizeText)"
        thumb.image = thumbnail
    }
}
