import CoreGraphics
import Foundation

/// PF-M: how a flight of the motion player reaches the window on every tick.
public enum MotionTransport: String, Equatable, Sendable {
    /// The app's motion lane writes each frame through Accessibility.
    case accessibility
    /// The WindowServer moves the window (one SkyLight transaction per tick
    /// for every such flight); Accessibility writes it only at the settle.
    case windowServer
}

/// PF-M: hide and reveal flights move through the WindowServer: a flight
/// that starts or ends hidden (no more than a parking sliver in any
/// viewport: columns leaving or entering the screen, workspace drops and
/// rises) and keeps its size the whole way (SkyLight never resizes: a
/// first-frame shrink or an interpolated size stays on Accessibility).
/// With the `ax` (or a fallen-back `snapshot`) renderer, flights between two
/// visible frames stay on Accessibility. Gio's own windows always do. With
/// the transport off, nothing changes.
/// PF-O: the `live` renderer moves every same-size flight through the
/// WindowServer, visible ones included: the real window moves at the
/// display's pace with live content, and its app learns the frame in the
/// final pass. A flight that resizes stays on its app's lane (only the app
/// can lay out a new size, and a SkyLight move racing the app's own
/// position-and-size write would fight it).
/// TG-03: the settle of a trackpad scroll (`gestureSettle`) does the same
/// with any renderer: the gesture already moved those windows through the
/// WindowServer on every frame, and the settle continues that motion.
/// Accessibility follows in the final pass as always.
public func planMotionTransports(
    _ animations: [WindowAnimation], viewports: [CGRect], enabled: Bool, ownPID: pid_t,
    renderer: RendererKind, gestureSettle: Bool = false
) -> [WindowAnimation] {
    guard enabled else {
        return animations
    }
    let moveVisible = renderer == .live || gestureSettle
    return animations.map { animation in
        var planned = animation
        let hides = !showsOnScreen(animation.to, in: viewports)
        let reveals = !showsOnScreen(animation.from, in: viewports)
        if animation.id.pid != ownPID, hides || reveals || moveVisible, keepsItsSize(animation) {
            planned.transport = .windowServer
        }
        return planned
    }
}

/// The frame written during the flight never changes size (FI-03 grows keep
/// the old size until the final pass; shrinks and size schedules do not).
private func keepsItsSize(_ animation: WindowAnimation) -> Bool {
    func same(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= frameWriteTolerance && abs(a.height - b.height) <= frameWriteTolerance
    }
    return same(animation.motionFrame(at: 0).size, animation.from.size)
        && same(animation.motionFrame(at: animation.duration).size, animation.from.size)
}
