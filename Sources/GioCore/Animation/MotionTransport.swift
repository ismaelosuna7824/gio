import CoreGraphics
import Foundation

/// PF-M: how an AX-renderer flight reaches the window on every tick.
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
/// Flights between two visible frames stay on Accessibility (only the app can
/// lay out a window the user sees move in place), and so does every window of
/// Gio's own pid. With the transport off, nothing changes. TG-03: the
/// settle of a trackpad scroll (`moveVisible`) moves every same-size flight
/// through the WindowServer, visible ones included: the gesture already
/// moved those windows there on every frame, and the settle continues that
/// motion; Accessibility follows in the final pass as always.
public func planMotionTransports(
    _ animations: [WindowAnimation], viewports: [CGRect], enabled: Bool, ownPID: pid_t, moveVisible: Bool = false
) -> [WindowAnimation] {
    guard enabled else {
        return animations
    }
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
