import CoreGraphics
import Foundation

/// What a failed write can tell the reconciler about itself. Adapter errors
/// (the AX actuator) and `FrameWriteError` conform, so `GioCore` reports a
/// stable kind and, for a mismatch, where the window actually landed,
/// without knowing the adapter's error type.
public protocol FrameFailureReporting: Error {
    /// Short, stable, log-safe kind such as `frameMismatch` or
    /// `writeFailed(size,-25205)`. Never carries titles.
    var failureKind: String { get }
    /// Where the window really is, when the failure is a landing mismatch.
    var failureActual: CGRect? { get }
}

extension FrameWriteError: FrameFailureReporting {
    public var failureKind: String { "frameMismatch" }

    public var failureActual: CGRect? {
        switch self {
        case .mismatch(let actual):
            return actual == .zero ? nil : actual
        }
    }
}

/// One failed window write, structured (FI-01). Frames are in the same
/// coordinate space as the layout; `nil` means unknown.
public struct ReconcileFailure: Equatable, Sendable {
    public var kind: String
    public var requested: CGRect?
    public var actual: CGRect?
    /// Free-form error text, kept only for kinds the reconciler cannot name.
    public var detail: String?

    public init(kind: String, requested: CGRect? = nil, actual: CGRect? = nil, detail: String? = nil) {
        self.kind = kind
        self.requested = requested
        self.actual = actual
        self.detail = detail
    }

    public static let frameMismatchKind = "frameMismatch"

    /// MM-11: the app did not answer in time (lane stall `timeout`, or the
    /// Accessibility call ended with `kAXErrorCannotComplete`, -25204): the
    /// same write may land a moment later. A refusal (mismatch, not
    /// settable, other errors) is not transient.
    public var isTransient: Bool {
        kind == "timeout" || kind.hasSuffix(",-25204)")
    }
}

/// MM-11: a write that failed only because its app was busy is tried again
/// (the window would otherwise stay where it was, on the wrong display after
/// a monitor move, until the next action touched it). Retries back off over
/// `delays` and then stop, so a hung app never loops; a successful write of
/// the window starts the backoff over.
public struct TransientWriteRetry: Sendable {
    /// The first lands after a short busy moment (a display change redraws
    /// the app); the last gives an app busy for ~3.5 s its window back.
    public static let delays: [TimeInterval] = [0.5, 1.0, 2.0]

    private var attempts: [WindowID: Int] = [:]

    public init() {}

    /// When to run the next retry pass for `report`'s busy windows, or
    /// `nil` when none is due (no transient failure, or backoff exhausted).
    public mutating func settle(_ report: ReconcileReport) -> TimeInterval? {
        for id in report.applied + report.alreadyCorrect + report.parked {
            attempts.removeValue(forKey: id)
        }
        var next: TimeInterval?
        for id in report.failed where report.failures[id]?.isTransient == true {
            let attempt = attempts[id, default: 0]
            guard attempt < Self.delays.count else {
                continue
            }
            attempts[id] = attempt + 1
            next = min(next ?? .infinity, Self.delays[attempt])
        }
        return next
    }
}

/// FX-07: one pass written under a snapshot overlay and its outcome.
public struct DispatchedOutcome: Sendable {
    public var report: ReconcileReport
    public var visible: [WindowID: CGRect]
    public var parked: [WindowID: ParkedTarget]

    public init(report: ReconcileReport, visible: [WindowID: CGRect], parked: [WindowID: ParkedTarget] = [:]) {
        self.report = report
        self.visible = visible
        self.parked = parked
    }
}

/// FX-07: the windows whose last write under the overlay failed only because
/// their app was busy (`isTransient`), with that pass's target, written
/// again before the overlay comes down. The busy moment (live: OrbStack
/// activating, ~200 ms) has usually passed by the end of the flight, while
/// the backoff retry (`TransientWriteRetry`, 0.5 s) left the window's slot
/// empty after the hand-over. Passes in dispatch order; a later outcome
/// wins, so a window a later pass placed is not retried.
public func retryBeforeHandOver(_ passes: [DispatchedOutcome]) -> ParkingPlan {
    var retry = ParkingPlan()
    for pass in passes {
        let report = pass.report
        for id in report.applied + report.alreadyCorrect + report.parked + report.vanished + report.deferred {
            retry.visible.removeValue(forKey: id)
            retry.parked.removeValue(forKey: id)
        }
        for id in report.failed {
            retry.visible.removeValue(forKey: id)
            retry.parked.removeValue(forKey: id)
            guard report.failures[id]?.isTransient == true else {
                continue
            }
            if let target = pass.parked[id] {
                retry.parked[id] = target
            } else if let frame = pass.visible[id] {
                retry.visible[id] = frame
            }
        }
    }
    return retry
}

/// `(x,y,w,h)` in whole points; non-finite or absurd values never crash.
public func formatFrame(_ frame: CGRect?) -> String {
    guard let frame else {
        return "none"
    }
    func whole(_ value: CGFloat) -> String {
        guard value.isFinite else {
            return "nan"
        }
        return String(Int(min(max(value.rounded(), -1e9), 1e9)))
    }
    return "(\(whole(frame.origin.x)),\(whole(frame.origin.y)),\(whole(frame.size.width)),\(whole(frame.size.height)))"
}

/// `reconcile failure id=P:E app=<name> kind=<kind> requested=(..) actual=(..)`.
/// IDs and app names only, never titles.
public func reconcileFailureLine(id: WindowID, app: String, failure: ReconcileFailure) -> String {
    var line = "reconcile failure id=\(id.pid):\(id.elementID) app=\(app) kind=\(failure.kind) "
        + "requested=\(formatFrame(failure.requested)) actual=\(formatFrame(failure.actual))"
    if let detail = failure.detail {
        line += " detail=\(detail)"
    }
    return line
}

/// Warn once per (window, kind) for the session; repeats drop to debug so a
/// window that keeps failing does not flood the log.
public struct FailureLogGate: Sendable {
    private var seen: Set<Key> = []

    private struct Key: Hashable, Sendable {
        let id: WindowID
        let kind: String
    }

    public init() {}

    public mutating func level(for id: WindowID, kind: String) -> LogLevel {
        seen.insert(Key(id: id, kind: kind)).inserted ? .warn : .debug
    }
}
