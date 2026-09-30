import AppKit
import GioCore
import QuartzCore

// NA-03: the close ghost. Main thread only. One tiny borderless,
// click-through, non-activating panel exactly the size of the closed window
// (never a full-screen backdrop, SM-07), showing the window's cached image.
// Core Animation fades it out while it shrinks around its centre, then the
// panel removes itself; the session's watchdog removal is idempotent.
// Level `.normal + 1`, like the snapshot overlay: above app windows, behind
// the focus ring, the Dock and the menu bar.

private final class GhostPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class GhostRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
public final class CloseGhostOverlay {
    private var panels: [Int: NSPanel] = [:]

    public init() {}

    /// Frames are Cocoa global coordinates.
    public func show(token: Int, image: CGImage, frame: CGRect, duration: TimeInterval, shrink: CGFloat) {
        guard frame.width >= 1, frame.height >= 1 else {
            return
        }
        let panel = GhostPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        let root = GhostRootView(frame: CGRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        let layer = CALayer()
        layer.frame = root.bounds
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = CGFloat(image.width) / max(frame.width, 1)
        root.layer?.addSublayer(layer)
        panel.contentView = root
        panels[token] = panel
        panel.orderFrontRegardless()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                self?.remove(token: token)
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1 - shrink
        let group = CAAnimationGroup()
        group.animations = [fade, scale]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.opacity = 0
        layer.add(group, forKey: "ghost")
        CATransaction.commit()
    }

    public func remove(token: Int) {
        guard let panel = panels.removeValue(forKey: token) else {
            return
        }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    public func stop() {
        for token in Array(panels.keys) {
            remove(token: token)
        }
    }
}
