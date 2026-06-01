import AppKit

/// First-run welcome that guides the user through granting Screen Recording, the one permission
/// every capture/recording feature needs. Shown once (tracked by Preferences.hasOnboarded).
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    /// Show on first launch only when access isn't already granted.
    static func showIfNeeded() {
        guard !Preferences.hasOnboarded, !PermissionsService.shared.isAuthorized else { return }
        shared.show()
    }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let size = NSSize(width: 460, height: 320)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Welcome to BetterShutter"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()

        let glass = GlassPanelView(cornerRadius: 0)
        window.contentView = glass
        let content = glass.contentView

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Capture anything on your screen")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center

        let body = NSTextField(wrappingLabelWithString:
            "BetterShutter needs Screen Recording permission to capture screenshots and record your screen. Grant it once to unlock every feature.")
        body.alignment = .center
        body.textColor = .secondaryLabelColor

        let grant = NSButton(title: "Grant Screen Recording", target: self, action: #selector(grantTapped))
        grant.bezelStyle = .rounded
        grant.keyEquivalent = "\r"

        let later = NSButton(title: "Maybe Later", target: self, action: #selector(laterTapped))
        later.bezelStyle = .rounded

        let buttons = NSStackView(views: [later, grant])
        buttons.spacing = 12

        let stack = NSStackView(views: [icon, title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
        ])
        self.window = window
    }

    @objc private func grantTapped() {
        // Triggers the system prompt the first time; afterwards it just opens Settings.
        if !PermissionsService.shared.requestAccess() {
            PermissionsService.shared.openSystemSettings()
        }
        finish()
    }

    @objc private func laterTapped() { finish() }

    private func finish() {
        Preferences.hasOnboarded = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) { Preferences.hasOnboarded = true }
}
