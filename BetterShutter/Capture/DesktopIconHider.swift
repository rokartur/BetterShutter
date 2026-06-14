import AppKit

/// Hides desktop icons during a capture or recording the seamless way: instead of toggling Finder's
/// `CreateDesktop` default (which forces a jarring Finder relaunch), it floats a wallpaper-filled
/// window per screen just above the desktop-icon layer and below normal windows. Icons vanish under
/// the matching wallpaper while app windows and the Dock keep drawing on top. Removing the windows
/// restores the icons instantly. Matches CleanShot X's "hide desktop icons".
@MainActor
final class DesktopIconHider {
    static let shared = DesktopIconHider()

    private var windows: [NSWindow] = []
    private var refCount = 0

    private init() {}

    var isHiding: Bool { !windows.isEmpty }

    /// Show the covers (idempotent across nested capture/recording lifecycles via a ref count).
    func hide() {
        refCount += 1
        guard windows.isEmpty else { return }
        // Just above the desktop-icon layer, far below normal windows (level 0) and the Dock.
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isOpaque = true
            window.level = level
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.backgroundColor = NSColor.windowBackgroundColor

            let imageView = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
            imageView.imageScaling = .scaleAxesIndependently
            imageView.autoresizingMask = [.width, .height]
            if let url = NSWorkspace.shared.desktopImageURL(for: screen),
               let image = NSImage(contentsOf: url) {
                imageView.image = image
            }
            window.contentView = imageView
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            window.displayIfNeeded()
            windows.append(window)
        }
    }

    /// Remove one hide request; the covers come down only when the last one is released.
    func show() {
        refCount = max(0, refCount - 1)
        guard refCount == 0 else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}
