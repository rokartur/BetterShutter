import AppKit

/// A small transient confirmation toast shown center-screen (e.g. "Text copied").
@MainActor
enum HUD {
    private static var current: NSPanel?

    static func show(_ text: String, duration: Double = 1.3) {
        current?.orderOut(nil)
        current = nil

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        let textSize = label.intrinsicContentSize
        let pad: CGFloat = 16
        let w = textSize.width + pad * 2
        let h = textSize.height + pad

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 10
        label.frame = NSRect(x: pad, y: pad / 2, width: textSize.width, height: textSize.height)
        container.addSubview(label)
        panel.contentView = container

        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.frame.midX - w / 2, y: screen.visibleFrame.midY))
        }
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        current = panel

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard current === panel else { return }
            panel.orderOut(nil)
            current = nil
        }
    }
}
