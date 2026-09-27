import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = WorkspaceApp()
app.delegate = controller
app.run()
