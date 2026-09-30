import CoreGraphics
import Foundation

// Native zoom for maximize (`[animations] native-zoom`).
//
// Writing a brand-new size makes some apps repaint from scratch (330-750 ms
// the first time a size is reached), while their own zoom (double-click on the
// title bar) animates smoothly in-process. When maximize-column grows a
// single-window column, Gio presses the app's zoom instead of writing the
// size, waits for the window to settle and then checks where it landed. All
// decisions are pure and live here; `SessionHost` only wires them to the
// reconciler, the WindowServer poll and the reflow.

public enum NativeZoomAction: String, Equatable, Sendable {
    case maximize
    case restore
}

public enum NativeZoomLimits {
    /// Every edge of the zoomed frame within this many points of the layout
    /// target (and inside the visible frame): the frame is exact, no write.
    /// Anything else gets one correcting write, so the maximized window keeps
    /// the tiling gaps instead of covering the whole screen.
    public static let acceptTolerance: CGFloat = 2
    /// Only for the log: within this many points the correction is a small
    /// inset (`corrected`); farther it is `fallback(mismatch)`. Both write once.
    public static let correctTolerance: CGFloat = 96
    /// Give up waiting for the zoom to settle after this many seconds. The app
    /// animates its zoom for about 250 ms and may start late.
    public static let settleTimeout: TimeInterval = 1.5
    /// Accessibility messaging timeout for the zoom button while the action is
    /// performed: the call blocks while the app runs its animation, so the
    /// short per-window timeout (PA-03) would report a false failure.
    public static let zoomMessagingTimeout: Float = 1.0
    /// Consecutive polls with the same bounds that count as settled.
    public static let stableFrames = 2
    /// Bounds within this many points are "the same" (rounding, jitter).
    public static let frameTolerance: CGFloat = 1
    /// Poll interval of the settle detection (about one 60 Hz frame).
    public static let pollInterval: TimeInterval = 0.016
}

// MARK: - Request and eligibility

/// What the maximize toggle asks of the native zoom, decided from the
/// workspace BEFORE the toggle is committed.
public struct NativeZoomRequest: Equatable, Sendable {
    public let id: WindowID
    public let action: NativeZoomAction
    public let columnWindowCount: Int
    /// The window's current maximize was done by a native zoom that is still
    /// in force (its accepted frame has not been dropped).
    public let wasNativeMaximized: Bool

    public init(id: WindowID, action: NativeZoomAction, columnWindowCount: Int, wasNativeMaximized: Bool) {
        self.id = id
        self.action = action
        self.columnWindowCount = columnWindowCount
        self.wasNativeMaximized = wasNativeMaximized
    }
}

/// The request for toggling maximize on the focused column; nil without a
/// focused window. A column that already remembers a width to restore is
/// maximized, so toggling it is a restore.
public func nativeZoomRequest(
    in workspace: Workspace, nativeMaximized: (WindowID) -> Bool
) -> NativeZoomRequest? {
    guard let column = workspace.focusedColumnRef, let id = column.focusedWindowID else {
        return nil
    }
    return NativeZoomRequest(
        id: id, action: column.savedWidthSpec == nil ? .maximize : .restore,
        columnWindowCount: column.windows.count, wasNativeMaximized: nativeMaximized(id)
    )
}

public enum NativeZoomSkipReason: String, Equatable, Sendable {
    case disabled
    case stackedColumn
    case notGrowing
    case notNativeMaximized
    case zoomUnavailable
    case noWindowServer
    /// Animations are off, or the snapshot renderer carries the motion.
    case noAxMotion
}

public enum NativeZoomEligibility: Equatable, Sendable {
    case eligible
    case ineligible(NativeZoomSkipReason)
}

/// First failing rule wins: config on, a single-window column, a maximize
/// that grows (or a restore of a native maximize), and a usable zoom button.
public func nativeZoomEligibility(
    _ request: NativeZoomRequest, enabled: Bool, grows: Bool, zoomAvailable: Bool
) -> NativeZoomEligibility {
    guard enabled else {
        return .ineligible(.disabled)
    }
    guard request.columnWindowCount == 1 else {
        return .ineligible(.stackedColumn)
    }
    switch request.action {
    case .maximize:
        guard grows else {
            return .ineligible(.notGrowing)
        }
    case .restore:
        guard request.wasNativeMaximized else {
            return .ineligible(.notNativeMaximized)
        }
    }
    guard zoomAvailable else {
        return .ineligible(.zoomUnavailable)
    }
    return .eligible
}

/// Whether a window at `from` gets larger by `to` in either dimension: the
/// growth that earns a native zoom.
public func nativeZoomGrows(from: CGRect, to: CGRect, tolerance: CGFloat = NativeZoomLimits.frameTolerance) -> Bool {
    to.width - from.width > tolerance || to.height - from.height > tolerance
}

// MARK: - Settling and acceptance

public enum NativeZoomFallbackReason: String, Equatable, Sendable {
    case pressFailed
    case unchanged
    case timeout
    case mismatch
    /// No usable zoom button (none, disabled, or only a full-screen button).
    case unavailable
    /// The window is not listed by the WindowServer, so its settle cannot be watched.
    case noWindowServer
    /// The window is no longer laid out on a display when the zoom ended.
    case notVisible
}

/// How the wait for one zoom ended.
public enum NativeZoomSettle: Equatable, Sendable {
    case settled(CGRect, milliseconds: Int)
    /// The bounds never changed before the timeout (the app ignored the zoom).
    case unchanged(milliseconds: Int)
    /// The bounds changed but never held still before the timeout.
    case timedOut(milliseconds: Int)
    /// The zoom could not be pressed (button gone, disabled, definitive AX
    /// error); `code` is the AXError raw value when there was one.
    case pressFailed(code: Int32?)

    public var milliseconds: Int {
        switch self {
        case .settled(_, let ms), .unchanged(let ms), .timedOut(let ms): return ms
        case .pressFailed: return 0
        }
    }

    /// The AXError of a failed press, for the log.
    public var errorCode: Int32? {
        if case .pressFailed(let code) = self {
            return code
        }
        return nil
    }
}

public enum NativeZoomOutcome: Equatable, Sendable {
    /// The app's frame is the layout target within 2 pt; no write.
    case exact
    /// One write to the exact layout target (the app's frame differs by a
    /// small inset, typically the tiling gaps).
    case corrected
    /// Ordinary write to the target (the PA-07 behavior).
    case fallback(NativeZoomFallbackReason)
}

/// Where did the zoom land relative to what the layout wants? `visible` is the
/// display's visible frame the accepted window must lie in.
public func nativeZoomOutcome(settle: NativeZoomSettle, target: CGRect, visible: CGRect) -> NativeZoomOutcome {
    switch settle {
    case .pressFailed:
        return .fallback(.pressFailed)
    case .unchanged:
        return .fallback(.unchanged)
    case .timedOut:
        return .fallback(.timeout)
    case .settled(let frame, _):
        let worst = worstEdgeDistance(frame, target)
        let inside = visible.insetBy(dx: -NativeZoomLimits.frameTolerance, dy: -NativeZoomLimits.frameTolerance)
            .contains(frame)
        if worst <= NativeZoomLimits.acceptTolerance, inside {
            return .exact
        }
        return worst <= NativeZoomLimits.correctTolerance ? .corrected : .fallback(.mismatch)
    }
}

private func worstEdgeDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    max(
        abs(lhs.minX - rhs.minX), abs(lhs.maxX - rhs.maxX),
        abs(lhs.minY - rhs.minY), abs(lhs.maxY - rhs.maxY)
    )
}

/// `native zoom id=<pid:elem> app=<name> action=maximize|restore result=exact|corrected|fallback(reason[:axerror]) ms=<n>`
/// IDs and app names only, never titles.
public func nativeZoomLogLine(
    id: WindowID, app: String, action: NativeZoomAction, outcome: NativeZoomOutcome, milliseconds: Int,
    errorCode: Int32? = nil
) -> String {
    let result: String
    switch outcome {
    case .exact: result = "exact"
    case .corrected: result = "corrected"
    case .fallback(let reason):
        if reason == .pressFailed, let errorCode {
            result = "fallback(\(reason.rawValue):\(errorCode))"
        } else {
            result = "fallback(\(reason.rawValue))"
        }
    }
    return "native zoom id=\(id.pid):\(id.elementID) app=\(app) action=\(action.rawValue) result=\(result) ms=\(milliseconds)"
}

/// Watches the WindowServer bounds of a zooming window. The window is settled
/// once its bounds changed and then held still for `stableFrames` consecutive
/// polls; `timeout` seconds after the press it gives up. Time is injected.
public struct NativeZoomSettleTracker: Sendable {
    private let start: CGRect
    private let stableFrames: Int
    private let timeout: TimeInterval
    private let tolerance: CGFloat
    private var last: CGRect?
    private var run = 0

    public init(
        start: CGRect, stableFrames: Int = NativeZoomLimits.stableFrames,
        timeout: TimeInterval = NativeZoomLimits.settleTimeout, tolerance: CGFloat = NativeZoomLimits.frameTolerance
    ) {
        self.start = start
        self.stableFrames = max(1, stableFrames)
        self.timeout = timeout
        self.tolerance = tolerance
    }

    /// One poll. `bounds` is nil when the WindowServer did not list the
    /// window. Returns nil while still waiting.
    public mutating func observe(_ bounds: CGRect?, elapsed: TimeInterval) -> NativeZoomSettle? {
        let milliseconds = Int((elapsed * 1000).rounded())
        if let bounds {
            if let previous = last {
                if similar(bounds, previous) {
                    run += 1
                } else {
                    last = bounds
                    run = 1
                }
            } else if !similar(bounds, start) {
                last = bounds
                run = 1
            }
            if let settled = last, run >= stableFrames {
                return .settled(settled, milliseconds: milliseconds)
            }
        }
        guard elapsed >= timeout else {
            return nil
        }
        return last == nil ? .unchanged(milliseconds: milliseconds) : .timedOut(milliseconds: milliseconds)
    }

    private func similar(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        worstEdgeDistance(lhs, rhs) <= tolerance
    }
}

// MARK: - Session bookkeeping

/// A settled (or failed) zoom waiting for the next reflow to judge it against
/// the layout target of that moment.
public struct NativeZoomResolution: Equatable, Sendable {
    public let id: WindowID
    public let action: NativeZoomAction
    public let settle: NativeZoomSettle
}

/// Per-session memory of native zooms: which windows are mid-zoom (excluded
/// from Gio's writes and motion), which finished and wait to be judged, and
/// which accepted frames replace the layout target. Session queue only.
public struct NativeZoomBook: Sendable {
    private struct Accepted: Sendable {
        let target: CGRect
        let actual: CGRect
    }

    private var flights: [WindowID: NativeZoomAction] = [:]
    private var resolved: [WindowID: NativeZoomResolution] = [:]
    private var accepted: [WindowID: Accepted] = [:]

    public init() {}

    public var inFlightIDs: Set<WindowID> { Set(flights.keys) }
    public var hasInFlight: Bool { !flights.isEmpty }

    public func isInFlight(_ id: WindowID) -> Bool {
        flights[id] != nil
    }

    /// In flight, or finished and waiting for the next reflow's verdict: its
    /// frame events are still expected and its focus ring stays hidden.
    public func isBusy(_ id: WindowID) -> Bool {
        flights[id] != nil || resolved[id] != nil
    }

    /// True while the window sits at a frame accepted from a native zoom.
    public func isNativeMaximized(_ id: WindowID) -> Bool {
        accepted[id] != nil
    }

    public mutating func begin(_ id: WindowID, action: NativeZoomAction) {
        flights[id] = action
        resolved.removeValue(forKey: id)
        accepted.removeValue(forKey: id)
    }

    /// The wait ended. A window that is not in flight is ignored.
    public mutating func finish(_ id: WindowID, settle: NativeZoomSettle) {
        guard let action = flights.removeValue(forKey: id) else {
            return
        }
        resolved[id] = NativeZoomResolution(id: id, action: action, settle: settle)
    }

    /// Windows whose zoom ended and still need a verdict, in id order.
    public mutating func takeResolved() -> [NativeZoomResolution] {
        defer { resolved.removeAll() }
        return resolved.values.sorted { $0.id < $1.id }
    }

    public var hasResolved: Bool { !resolved.isEmpty }

    public mutating func accept(_ id: WindowID, target: CGRect, actual: CGRect) {
        accepted[id] = Accepted(target: target, actual: actual)
    }

    public mutating func forget(_ id: WindowID) {
        flights.removeValue(forKey: id)
        resolved.removeValue(forKey: id)
        accepted.removeValue(forKey: id)
    }

    /// Frames minus the windows mid-zoom: nothing of Gio writes them.
    public func withoutInFlight(_ frames: [WindowID: CGRect]) -> [WindowID: CGRect] {
        guard !flights.isEmpty else {
            return frames
        }
        return frames.filter { flights[$0.key] == nil }
    }

    /// Substitute the accepted frame for the layout target while that target
    /// is unchanged (within a point). A window whose target moved, or that is
    /// parked, no longer sits where the zoom left it: its acceptance is dropped.
    public mutating func applyAccepted(to frames: [WindowID: CGRect], parked: Set<WindowID>) -> [WindowID: CGRect] {
        guard !accepted.isEmpty else {
            return frames
        }
        var result = frames
        for id in accepted.keys {
            if parked.contains(id) {
                accepted.removeValue(forKey: id)
            } else if let target = frames[id] {
                let entry = accepted[id]!
                if worstEdgeDistance(target, entry.target) <= NativeZoomLimits.frameTolerance {
                    result[id] = entry.actual
                } else {
                    accepted.removeValue(forKey: id)
                }
            }
        }
        return result
    }
}

/// While a native zoom flies, its window's frame and focus events are
/// expected: no rescan, no trust invalidation storm, no focus adoption scroll.
public func nativeZoomDropsEvent(_ kind: WindowEventKind, inFlight: Bool) -> Bool {
    guard inFlight else {
        return false
    }
    switch kind {
    case .moved, .resized, .focusedWindowChanged:
        return true
    case .windowCreated, .miniaturized, .deminiaturized, .titleChanged, .destroyed:
        return false
    }
}

// MARK: - Zoom through the actuator

public enum ZoomAvailability: Equatable, Sendable {
    case available
    /// No zoom button, disabled, or otherwise not pressable; the reason is a
    /// short stable word for the log.
    case unavailable(String)
}

public enum ZoomPressResult: Equatable, Sendable {
    case pressed
    /// The action errored the way a busy app does (timeout class): the zoom
    /// may still be running or about to run. Watch the window, never write it.
    case pending(code: Int32?)
    /// A definitive AX error (unsupported action, invalid element...).
    case failed(code: Int32)
    case unavailable(String)
}

public enum NativeZoomActionErrorClass: Equatable, Sendable {
    /// The zoom may still happen; wait for the window to settle.
    case pending
    /// The action can never work now; write the target immediately.
    case definitive
}

/// `kAXErrorCannotComplete` (-25204) is what a messaging timeout or a busy
/// app returns, and the app can still zoom afterwards. Every other error
/// (failure, illegal argument, invalid element, unsupported action, not
/// implemented, API disabled...) is definitive.
public func nativeZoomActionErrorClass(_ code: Int32) -> NativeZoomActionErrorClass {
    code == -25204 ? .pending : .definitive
}

/// The press result of one `AXUIElementPerformAction` status (0 is success).
public func zoomPressResult(forActionStatus code: Int32) -> ZoomPressResult {
    if code == 0 {
        return .pressed
    }
    switch nativeZoomActionErrorClass(code) {
    case .pending: return .pending(code: code)
    case .definitive: return .failed(code: code)
    }
}

public enum NativeZoomPressDisposition: Equatable, Sendable {
    /// Poll the WindowServer bounds until they settle or time out.
    case watch
    /// Stop now; the window is written to the target by the ordinary pass.
    case fallbackNow(NativeZoomSettle)
}

public func nativeZoomPressDisposition(_ result: ZoomPressResult) -> NativeZoomPressDisposition {
    switch result {
    case .pressed, .pending: return .watch
    case .failed(let code): return .fallbackNow(.pressFailed(code: code))
    case .unavailable: return .fallbackNow(.pressFailed(code: nil))
    }
}
