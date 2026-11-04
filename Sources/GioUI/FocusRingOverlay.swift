import AppKit
import GioCore
import QuartzCore

/// The overlay window: never key, never main, never activating, and free to
/// sit partly off-screen (borderless windows are not constrained, but the
/// override makes that explicit for a ring around a half-scrolled window).
private final class FocusRingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Draws one rounded-rect stroke. Layer-backed; path and color change only
/// when the geometry does, with implicit animations disabled (the window
/// motion already animates the frame).
private final class FocusRingView: NSView {
    private let shape = CAShapeLayer()
    private var applied: FocusRingGeometry?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shape.fillColor = nil
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ ring: FocusRingGeometry) {
        guard ring != applied else {
            return
        }
        applied = ring
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = CGRect(origin: .zero, size: ring.frame.size)
        shape.path = CGPath(
            roundedRect: ring.strokeRect, cornerWidth: ring.strokeCornerRadius,
            cornerHeight: ring.strokeCornerRadius, transform: nil
        )
        shape.lineWidth = ring.width
        shape.strokeColor = NSColor(
            srgbRed: ring.color.red, green: ring.color.green, blue: ring.color.blue, alpha: 1
        ).cgColor
        CATransaction.commit()
    }
}

/// NF-01 focus ring overlay. Main thread only; it is fed `FocusRingState`
/// values the session queue published (coalesced, latest wins) and makes no
/// Accessibility call. The panel belongs to Gio's own process, so it can
/// never be registered as a managed window (own-pid guards, bac43c6).
@MainActor
public final class FocusRingController {
    private var panel: FocusRingPanel?
    private var ringView: FocusRingView?
    private var state: FocusRingState = .hidden
    private var isShown = false
    /// WC-18: macOS is showing its own overview (Mission Control, App Exposé):
    /// the panel must not sit at the window's real frame as an empty border.
    private var systemOverview = false
    private var observers: [NSObjectProtocol] = []

    public init() {}

    /// Start following whether Gio holds the user's attention: the ring hides
    /// while Gio is the frontmost app (main window) or one of its windows is
    /// key (the overview and the launcher are non-activating panels: another
    /// app stays frontmost, and the ring showed through the translucent
    /// overview). `NSApplication.isActive` is not used: it reads true while
    /// such a panel is key without posting the app's activation
    /// notifications, so a ring published then stayed masked (live: an
    /// overview pick onto another app's window). Every app activation and
    /// every key change of Gio's windows refreshes it; key changes on the next
    /// turn, once AppKit updated the key window.
    public func start() {
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.refresh()
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated { self?.refresh() }
                        }
                    }
                }
            )
        }
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        )
    }

    public func apply(_ next: FocusRingState) {
        state = next
        refresh()
    }

    /// WC-18: step aside while macOS shows its own overview of the windows.
    public func setSystemOverview(_ showing: Bool) {
        guard showing != systemOverview else {
            return
        }
        systemOverview = showing
        refresh()
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        state = .hidden
        refresh()
        panel?.close()
        panel = nil
        ringView = nil
    }

    private func refresh() {
        let gioHoldsFocus = NSApplication.shared.keyWindow != nil
            || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        switch systemOverview ? .hidden : state.masked(gioIsFrontmost: gioHoldsFocus) {
        case .hidden:
            if isShown {
                panel?.orderOut(nil)
                isShown = false
                GioLog.record(.debug, "focus ring hidden")
            }
        case .shown(let ring):
            let (panel, view) = makePanel()
            view.update(ring)
            if panel.frame != ring.frame {
                panel.setFrame(ring.frame, display: false)
            }
            place(panel, above: ring.windowNumber)
            if !isShown {
                isShown = true
                GioLog.record(.debug, "focus ring shown")
            }
        }
    }

    /// NF-13: a ring whose window's number is known sits right above that
    /// window at its level, so Gio's own window, a floating popup or another
    /// app's window over it covers the ring too (before: the ring floated
    /// above everything, across Gio's main window). Without a number it stays
    /// at `.floating`, above every ordinary window. Front without activating:
    /// the app and the focused window keep key status.
    private func place(_ panel: FocusRingPanel, above number: UInt32?) {
        if let number {
            if panel.level != .normal {
                panel.level = .normal
            }
            panel.order(.above, relativeTo: Int(number))
        } else if panel.level != .floating || !isShown {
            panel.level = .floating
            panel.orderFrontRegardless()
        }
    }

    /// NF-13, main thread: the focused window moved in the stack (a click
    /// raised it over the ring); put the ring back right above it.
    public func focusedWindowReordered() {
        guard isShown, let panel, case .shown(let ring) = state, let number = ring.windowNumber else {
            return
        }
        panel.order(.above, relativeTo: Int(number))
    }

    private func makePanel() -> (FocusRingPanel, FocusRingView) {
        if let panel, let ringView {
            return (panel, ringView)
        }
        let panel = FocusRingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Without a window number (`place`), `.floating` keeps the ring above
        // ordinary app windows (level 0), below menus, Spotlight and the
        // screen saver.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        let view = FocusRingView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        self.panel = panel
        self.ringView = view
        return (panel, view)
    }
}
