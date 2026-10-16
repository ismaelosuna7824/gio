import AppKit
import SwiftUI

/// The first-run setup covers the whole display of the main window, like
/// macOS's own Setup Assistant, instead of a sheet on the window. While Gio
/// is the active app the cover sits above the menu bar and the Dock; when
/// the user goes to System Settings to grant a permission it drops to the
/// normal level so System Settings shows on top, and rises again when Gio
/// is active. Gio never manages its own windows, so tiling ignores it.
@MainActor
final class SetupCoverController {
    private var window: NSWindow?
    private var hosting: NSHostingController<AnyView>?
    private var observers: [NSObjectProtocol] = []

    /// Above the menu bar and the Dock.
    private static let coverLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)

    func present(_ root: AnyView, on screen: NSScreen?) {
        if let hosting {
            hosting.rootView = root
            return
        }
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let window = SetupCoverWindow(
            contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.contentViewController = hosting
        window.setFrame(screen.frame, display: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.level = NSApplication.shared.isActive ? Self.coverLevel : .normal
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            window.animator().alphaValue = 1
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.window?.level = .normal }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.window?.level = Self.coverLevel
                    self?.window?.makeKeyAndOrderFront(nil)
                }
            },
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let window = self?.window, let screen = window.screen ?? NSScreen.main else {
                        return
                    }
                    window.setFrame(screen.frame, display: true)
                }
            },
        ]
        self.window = window
        self.hosting = hosting
    }

    func dismiss() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        hosting = nil
        guard let window else {
            return
        }
        self.window = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.close()
            }
        }
    }
}

/// Borderless windows cannot become key by default; the setup needs the
/// keyboard (Return continues).
private final class SetupCoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Anchors a `SetupCoverController` in the view tree: the cover shows on the
/// display of the window holding this view.
private struct SetupCoverAnchor: NSViewRepresentable {
    let isPresented: Bool
    let content: AnyView

    final class Coordinator {
        let controller = MainActor.assumeIsolated { SetupCoverController() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        if isPresented {
            context.coordinator.controller.present(content, on: view.window?.screen)
        } else {
            context.coordinator.controller.dismiss()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.controller.dismiss()
    }
}

extension View {
    /// Shows `content` full screen while `isPresented` (see `SetupCoverController`).
    func setupCover<Content: View>(isPresented: Bool, @ViewBuilder content: () -> Content) -> some View {
        background(SetupCoverAnchor(isPresented: isPresented, content: AnyView(content())))
    }
}
