import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar agent: no Dock icon, no main window.
app.setActivationPolicy(.accessory)
app.run()
