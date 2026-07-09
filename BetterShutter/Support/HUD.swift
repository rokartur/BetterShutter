import AppKit

/// A small transient confirmation toast shown center-screen (e.g. "Text copied").
@MainActor
enum HUD {
    private static var current: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(_ text: String, duration: Double = 1.3) {
        dismissTask?.cancel()
        dismissTask = nil
        current?.close()
        current = nil

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        let textSize = label.intrinsicContentSize
        let pad: CGFloat = 16
        let w = textSize.width + pad * 2
        let h = textSize.height + pad

        let panel = NSPanel.glassChrome(size: NSSize(width: w, height: h), level: .statusBar)

        let glass = GlassPanelView(cornerRadius: 12)
        glass.frame = NSRect(x: 0, y: 0, width: w, height: h)
        label.frame = NSRect(x: pad, y: pad / 2, width: textSize.width, height: textSize.height)
        glass.contentView.addSubview(label)
        panel.contentView = glass

        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.frame.midX - w / 2, y: screen.visibleFrame.midY))
        }
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        current = panel

        dismissTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(max(0, duration)))
            } catch {
                return
            }
            guard current === panel else { return }
            panel.close()
            current = nil
            dismissTask = nil
        }
    }
}
