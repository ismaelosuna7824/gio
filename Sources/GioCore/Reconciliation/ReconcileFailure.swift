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
/// once (the window would otherwise stay where it was, on the wrong display
/// after a monitor move, until the next action touched it). A retry that
/// fails again is not retried, so a hung app never loops; a successful
/// write of the window allows a retry again later.
public struct TransientWriteRetry: Sendable {
    /// After the app's busy moment (a display change redraws it), still
    /// before the user notices a window left behind.
    public static let delay: TimeInterval = 0.5

    private var retried: Set<WindowID> = []

    public init() {}

    /// The windows of `report` to write again after `delay`.
    public mutating func settle(_ report: ReconcileReport) -> [WindowID] {
        retried.subtract(report.applied + report.alreadyCorrect + report.parked)
        let due = report.failed.filter { id in
            report.failures[id]?.isTransient == true && !retried.contains(id)
        }
        retried.formUnion(due)
        return due.sorted()
    }
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
