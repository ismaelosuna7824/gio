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
    private var observers: [NSObjectProtocol] = []

    public init() {}

    /// Start following Gio's own activation: the ring hides while Gio is the
    /// active app (main window, launcher) and returns when it resigns.
    public func start() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            )
        }
    }

    public func apply(_ next: FocusRingState) {
        state = next
        refresh()
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        state = .hidden
        refresh()
        panel?.close()
        panel = nil
        ringView = nil
    }

    private func refresh() {
        switch state.masked(gioIsFrontmost: NSApplication.shared.isActive) {
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
            if !isShown {
                // Front without activating: the app and the focused window
                // keep key status.
                panel.orderFrontRegardless()
                isShown = true
                GioLog.record(.debug, "focus ring shown")
            }
        }
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
        // `.floating` keeps the ring above ordinary app windows (level 0) so
        // it is never covered by the window it frames or its neighbours, yet
        // below menus, Spotlight and the screen saver.
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
