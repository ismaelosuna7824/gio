import AppKit
import GioCore
import QuartzCore

/// Never key, never main, never activating; one per display, sized to it.
private final class FocusDimPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// One black fill layer; the path is replaced without implicit animation,
/// only its opacity fades.
private final class FocusDimView: NSView {
    let shape = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shape.fillColor = NSColor.black.cgColor
        shape.opacity = 0
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// NF-06 dim overlay: darkens the visible unfocused tiled windows at rest.
/// Main thread only; fed `FocusDimState` values the session queue published
/// (coalesced through a `LatestValueMailbox`) and makes no Accessibility or
/// WindowServer call. The panels are Gio's own, click-through, and sit at
/// `normal + 1`: above every app's ordinary windows (the regions already
/// exclude whatever is in front of a dimmed window) and below floating
/// panels, the focus ring (`.floating`), menus, the Dock and Spotlight.
@MainActor
public final class FocusDimController {
    /// Just above ordinary windows, below `.floating` (3).
    public static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)

    private var panels: [String: (panel: FocusDimPanel, view: FocusDimView)] = [:]
    private var visible: Set<String> = []
    private var state: FocusDimState = .hidden(.disabled)
    /// Bumped on every apply so a fade-out's completion never orders out a
    /// panel that was shown again meanwhile.
    private var generation = 0

    public init() {}

    public func apply(_ next: FocusDimState) {
        guard next != state else {
            return
        }
        // SM-08: coming out of a snapshot flight the overlay's own dim was
        // already there at full strength; the live one appears in place.
        let afterFlight = state == .hidden(.flight)
        state = next
        generation += 1
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch next {
        case .hidden:
            if !visible.isEmpty {
                fadeOut(keys: visible, reduceMotion: reduceMotion)
                visible = []
                GioLog.record(.debug, next.logLine)
            }
        case .shown(let regions, let strength):
            let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let alpha = Float(focusDimAlpha(strength: strength, darkAppearance: dark))
            var shown: Set<String> = []
            for region in regions {
                let key = NSStringFromRect(region.display)
                let (panel, view) = makePanel(key: key, frame: region.display)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                view.shape.frame = CGRect(origin: .zero, size: region.display.size)
                view.shape.path = dimPath(region)
                CATransaction.commit()
                if !visible.contains(key) {
                    panel.orderFrontRegardless()
                    fade(
                        view, to: alpha,
                        duration: focusDimFadeDuration(showing: true, reduceMotion: reduceMotion, afterFlight: afterFlight)
                    )
                } else if view.shape.opacity != alpha {
                    fade(view, to: alpha, duration: 0)
                }
                shown.insert(key)
            }
            let gone = visible.subtracting(shown)
            if !gone.isEmpty {
                fadeOut(keys: gone, reduceMotion: reduceMotion)
            }
            visible = shown
            GioLog.record(.debug, next.logLine)
        }
    }

    public func stop() {
        apply(.hidden(.shutdown))
        for entry in panels.values {
            entry.panel.close()
        }
        panels = [:]
        visible = []
    }

    private func fade(_ view: FocusDimView, to opacity: Float, duration: TimeInterval) {
        CATransaction.begin()
        if duration > 0 {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = view.shape.presentation()?.opacity ?? view.shape.opacity
            animation.toValue = opacity
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.shape.add(animation, forKey: "fade")
        } else {
            view.shape.removeAnimation(forKey: "fade")
        }
        CATransaction.setDisableActions(true)
        view.shape.opacity = opacity
        CATransaction.commit()
    }

    private func fadeOut(keys: Set<String>, reduceMotion: Bool) {
        let duration = focusDimFadeDuration(showing: false, reduceMotion: reduceMotion)
        let token = generation
        for key in keys {
            guard let entry = panels[key] else {
                continue
            }
            fade(entry.view, to: 0, duration: duration)
            guard duration > 0 else {
                entry.panel.orderOut(nil)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token || !self.visible.contains(key) else {
                        return
                    }
                    entry.panel.orderOut(nil)
                }
            }
        }
    }

    /// Each window's pieces, clipped to the window's rounded corners, in
    /// panel-local coordinates.
    private func dimPath(_ region: FocusDimDisplay) -> CGPath {
        let origin = region.display.origin
        let path = CGMutablePath()
        for window in region.windows {
            let pieces = CGMutablePath()
            pieces.addRects(window.rects.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) })
            let rounded = CGPath(
                roundedRect: window.bounds.offsetBy(dx: -origin.x, dy: -origin.y),
                cornerWidth: focusRingWindowCornerRadius, cornerHeight: focusRingWindowCornerRadius,
                transform: nil
            )
            path.addPath(rounded.intersection(pieces))
        }
        return path
    }

    private func makePanel(key: String, frame: CGRect) -> (FocusDimPanel, FocusDimView) {
        if let entry = panels[key] {
            return entry
        }
        let panel = FocusDimPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = Self.panelLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.setFrame(frame, display: false)
        let view = FocusDimView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panels[key] = (panel, view)
        return (panel, view)
    }
}
