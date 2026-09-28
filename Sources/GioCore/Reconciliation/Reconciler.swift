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
        vanished: [WindowID] = [],
        failed: [WindowID] = [],
        failureNotes: [WindowID: String] = [:],
        focusChanged: Bool = false,
        focusFailed: Bool = false
    ) {
        self.applied = applied
        self.alreadyCorrect = alreadyCorrect
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

    @discardableResult
    public func reconcile(
        frames: [WindowID: CGRect],
        focused: WindowID?,
        currentlyFocused: WindowID?
    ) -> ReconcileReport {
        var report = ReconcileReport()
        for id in frames.keys.sorted() {
            let desired = frames[id]!
            let actual: CGRect?
            do {
                actual = try actuator.frame(of: id)
            } catch {
                report.failed.append(id)
                report.failureNotes[id] = String(describing: error)
                continue
            }
            guard let actual else {
                report.vanished.append(id)
                continue
            }
            guard !matches(desired, actual) else {
                report.alreadyCorrect.append(id)
                continue
            }
            do {
                try actuator.setFrame(desired, for: id)
                report.applied.append(id)
            } catch {
                report.failed.append(id)
                report.failureNotes[id] = String(describing: error)
            }
        }
        if let focused, focused != currentlyFocused {
            do {
                try actuator.focus(id: focused)
                report.focusChanged = true
            } catch {
                report.focusFailed = true
            }
        }
        GioLog.record(
            .debug,
            "reconcile applied=\(report.applied.count) already=\(report.alreadyCorrect.count) vanished=\(report.vanished.count) failed=\(report.failed.count)"
        )
        if !report.failed.isEmpty {
            GioLog.record(.warn, "reconcile failures persist; see firstFailure in tile report")
        }
        return report
    }

    private func matches(_ requested: CGRect, _ actual: CGRect) -> Bool {
        abs(requested.origin.x - actual.origin.x) <= tolerance
            && abs(requested.origin.y - actual.origin.y) <= tolerance
            && abs(requested.size.width - actual.size.width) <= tolerance
            && abs(requested.size.height - actual.size.height) <= tolerance
    }
}
