import AppKit
import SwiftUI

/// The first-run setup covers the whole display of the main window, like
/// macOS's own Setup Assistant, instead of a sheet on the window. While Gio
/// is the active app the cover sits above the menu bar and the Dock; when
/// the user goes to System Settings, or a step asks macOS for a permission,
/// it drops to the normal level so System Settings and macOS's permission
/// alert show on top (the alert comes up while Gio stays active, and a raised
/// cover hid it), and rises again when Gio is active again. Gio never
/// manages its own windows, so tiling ignores it.
@MainActor
final class SetupCoverController {
    private var window: NSWindow?
    private var hosting: NSHostingController<AnyView>?
    private var observers: [NSObjectProtocol] = []
    private var stacking = SetupCoverStacking(appIsActive: false)

    /// Above the menu bar and the Dock.
    private static let coverLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)

    func present(_ root: AnyView, on screen: NSScreen?) {
        let root = AnyView(root.environment(\.setupCoverYield, SetupCoverYield { [weak self] in
            self?.stacking.permissionRequested()
            self?.applyStacking()
        }))
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
        stacking = SetupCoverStacking(appIsActive: NSApplication.shared.isActive)
        window.level = stacking.isRaised ? Self.coverLevel : .normal
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            window.animator().alphaValue = 1
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stacking.appResignedActive()
                    self?.applyStacking()
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stacking.appBecameActive()
                    self?.applyStacking()
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

    private func applyStacking() {
        window?.level = stacking.isRaised ? Self.coverLevel : .normal
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

/// Whether the setup cover sits above the menu bar. Raised only while Gio is
/// active and no permission request is pending: a request lowers it until Gio
/// becomes active again, because macOS shows its permission alert without
/// taking activation from Gio.
struct SetupCoverStacking: Equatable {
    private var appIsActive: Bool
    private var permissionPending = false

    init(appIsActive: Bool) {
        self.appIsActive = appIsActive
    }

    var isRaised: Bool { appIsActive && !permissionPending }

    mutating func permissionRequested() {
        permissionPending = true
    }

    mutating func appResignedActive() {
        appIsActive = false
    }

    mutating func appBecameActive() {
        appIsActive = true
        permissionPending = false
    }
}

/// Lowers the presenting setup cover before a step asks macOS for a
/// permission (see `SetupCoverStacking`). A no-op outside the cover.
struct SetupCoverYield {
    let perform: @MainActor () -> Void

    @MainActor func callAsFunction() {
        perform()
    }
}

private struct SetupCoverYieldKey: EnvironmentKey {
    static let defaultValue = SetupCoverYield {}
}

extension EnvironmentValues {
    var setupCoverYield: SetupCoverYield {
        get { self[SetupCoverYieldKey.self] }
        set { self[SetupCoverYieldKey.self] = newValue }
    }
}

/// Borderless windows cannot become key by default; the setup needs the
/// keyboard (Return continues).
final class SetupCoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// DA-16: the setup cover is on screen (its steps send you to System
/// Settings; the main window stays open meanwhile).
@MainActor
var isSetupCoverShowing: Bool {
    NSApplication.shared.windows.contains { $0 is SetupCoverWindow && $0.isVisible }
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
