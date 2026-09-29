import CoreGraphics
import Foundation

/// Plan §14 actuator: the physical side of reconciliation. Implementations
/// live in adapter layers (GioMacOS); this protocol keeps `GioCore`
/// macOS-free. `frame(of:)` returns nil for vanished windows — absence is
/// data, never an error.
public protocol WindowActuator: AnyObject {
    func frame(of id: WindowID) throws -> CGRect?
    func setFrame(_ frame: CGRect, for id: WindowID) throws
    func focus(id: WindowID) throws
}

/// What one `reconcile` pass did, in deterministic (sorted) order.
/// Failures are recorded by ID and never abort the batch: every other
/// window is still attempted. Underlying causes stay with the actuator
/// layer, which can log its typed errors; this report is the honest,
/// sendable outcome.
public struct ReconcileReport: Equatable, Sendable {
    public var applied: [WindowID]
    public var alreadyCorrect: [WindowID]
    /// Off-viewport windows written to their parking spot (already-parked
    /// ones count as `alreadyCorrect`).
    public var parked: [WindowID]
    public var vanished: [WindowID]
    public var failed: [WindowID]
    /// First error description per failed window, so live retests report
    /// causes instead of bare IDs. Deterministic: sorted by ID on read.
    public var failureNotes: [WindowID: String]
    public var focusChanged: Bool
    public var focusFailed: Bool

    public init(
        applied: [WindowID] = [],
        alreadyCorrect: [WindowID] = [],
        parked: [WindowID] = [],
        vanished: [WindowID] = [],
        failed: [WindowID] = [],
        failureNotes: [WindowID: String] = [:],
        focusChanged: Bool = false,
        focusFailed: Bool = false
    ) {
        self.applied = applied
        self.alreadyCorrect = alreadyCorrect
        self.parked = parked
        self.vanished = vanished
        self.failed = failed
        self.failureNotes = failureNotes
        self.focusChanged = focusChanged
        self.focusFailed = focusFailed
    }

    /// Deterministic first failure for display.
    public var firstFailure: String? {
        failureNotes.keys.sorted().first.flatMap { failureNotes[$0] }
    }
}

/// Plan §14: the ONLY component authorized to physically modify windows.
/// Desired state in, minimal writes out: frames within `tolerance` are
/// skipped, vanished windows are recorded, and focus is applied last so the
/// target keeps it. Pure `GioCore` — test with a mock actuator.
public final class WindowReconciler<Actuator: WindowActuator> {
    private let actuator: Actuator
    private let tolerance: CGFloat

    public init(actuator: Actuator, tolerance: CGFloat = 1) {
        self.actuator = actuator
        self.tolerance = tolerance
    }

    /// Parked windows are written first (outgoing before incoming, less
    /// flashing) and are never focused. A parked write counts as done when
    /// the window keeps its size and only a small strip stays on the
    /// intended side, because macOS may clamp the position.
    @discardableResult
    public func reconcile(
        frames: [WindowID: CGRect],
        parked: [WindowID: ParkedTarget] = [:],
        focused: WindowID?,
        currentlyFocused: WindowID?
    ) -> ReconcileReport {
        var report = ReconcileReport()
        for id in parked.keys.sorted() {
            reconcileOne(id, desired: parked[id]!.frame, parkedTarget: parked[id], into: &report)
        }
        for id in frames.keys.sorted() where parked[id] == nil {
            reconcileOne(id, desired: frames[id]!, parkedTarget: nil, into: &report)
        }
        if let focused, focused != currentlyFocused, parked[focused] == nil {
            do {
                try actuator.focus(id: focused)
                report.focusChanged = true
            } catch {
                report.focusFailed = true
            }
        }
        GioLog.record(
            .debug,
            "reconcile applied=\(report.applied.count) parked=\(report.parked.count) already=\(report.alreadyCorrect.count) vanished=\(report.vanished.count) failed=\(report.failed.count)"
        )
        if !report.failed.isEmpty {
            GioLog.record(.warn, "reconcile failures persist; see firstFailure in tile report")
        }
        return report
    }

    private func reconcileOne(
        _ id: WindowID, desired: CGRect, parkedTarget: ParkedTarget?, into report: inout ReconcileReport
    ) {
        let actual: CGRect?
        do {
            actual = try actuator.frame(of: id)
        } catch {
            report.failed.append(id)
            report.failureNotes[id] = String(describing: error)
            return
        }
        guard let actual else {
            report.vanished.append(id)
            return
        }
        if matches(desired, actual) || parkedTarget.map({ isParked(actual, $0) }) == true {
            report.alreadyCorrect.append(id)
            return
        }
        do {
            try actuator.setFrame(desired, for: id)
            record(id, parkedTarget != nil, into: &report)
        } catch {
            // macOS may clamp a parked position; accept a landing that is
            // still parked (size kept, small strip on the intended side).
            if let parkedTarget, let landed = try? actuator.frame(of: id), isParked(landed, parkedTarget) {
                GioLog.record(.debug, "parked clamped id=\(id.pid):\(id.elementID)")
                record(id, true, into: &report)
                return
            }
            report.failed.append(id)
            report.failureNotes[id] = String(describing: error)
        }
    }

    private func record(_ id: WindowID, _ isParkedWrite: Bool, into report: inout ReconcileReport) {
        if isParkedWrite {
            report.parked.append(id)
        } else {
            report.applied.append(id)
        }
    }

    /// Largest strip of a parked window allowed inside its display.
    public static var maxParkedStrip: CGFloat { 40 }

    private func isParked(_ actual: CGRect, _ target: ParkedTarget) -> Bool {
        guard abs(actual.width - target.frame.width) <= tolerance,
              abs(actual.height - target.frame.height) <= tolerance
        else {
            return false
        }
        let inside = actual.intersection(target.display)
        let strip = Self.maxParkedStrip
        let visibleWidth = inside.isNull ? 0 : inside.width
        let visibleHeight = inside.isNull ? 0 : inside.height
        switch target.edge {
        case .left:
            return actual.minX < target.display.minX && visibleWidth <= strip
        case .right:
            return actual.maxX > target.display.maxX && visibleWidth <= strip
        case .corner:
            return visibleWidth <= strip && visibleHeight <= strip
        }
    }

    private func matches(_ requested: CGRect, _ actual: CGRect) -> Bool {
        abs(requested.origin.x - actual.origin.x) <= tolerance
            && abs(requested.origin.y - actual.origin.y) <= tolerance
            && abs(requested.size.width - actual.size.width) <= tolerance
            && abs(requested.size.height - actual.size.height) <= tolerance
    }
}
