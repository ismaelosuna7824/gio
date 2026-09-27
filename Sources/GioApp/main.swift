import AppKit

// A macOS application enters on the main thread; keep AppKit setup on its actor.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = WorkspaceApp()
    app.delegate = controller
    app.run()
}
