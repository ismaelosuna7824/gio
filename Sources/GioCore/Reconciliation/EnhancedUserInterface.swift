import Foundation

/// PF-K: an app's `AXEnhancedUserInterface` attribute. Assistive apps
/// (VoiceOver) turn it on; while it is on, Chromium/Electron and some AppKit
/// apps take a slow, animated path for every frame Gio writes. Implemented in
/// GioMacOS over Accessibility; `GioCore` only decides when to switch it.
public protocol EnhancedUserInterfaceSwitch: AnyObject, Sendable {
    /// The app's current value; nil when it cannot be read.
    func enhancedUserInterface(pid: pid_t) -> Bool?
    /// Writes the value; false when the app did not take it (error, timeout).
    func setEnhancedUserInterface(_ on: Bool, pid: pid_t) -> Bool
}

/// PF-K: switches `AXEnhancedUserInterface` off for one write batch of an
/// app and back on at its end, so an assistive app never finds it off for
/// longer than Gio's writes take:
/// - a batch is one lane run that writes frames (a reconcile or dispatched
///   lane, a pre-position or nudge lane): the lane calls `willWrite` before
///   each frame write and `batchEnded` once, on its own thread, while it
///   still holds the app. A motion is one batch from its first frame to the
///   app's final-pass lane (motion lanes never end it: a switch per frame
///   would make the app rebuild its accessibility state every frame);
/// - only an app whose value read `true` is written, Gio's own pid never;
/// - the value is read at most once per `stateLifetime` per app, and never
///   while the app is still off because of Gio (it would read Gio's `false`);
/// - an app Gio left off (a motion the final pass did not visit, a restore
///   the hung app did not take) stays pending: its next batch ends with the
///   restore, and `restore(pid:)` retries it from the session's settle.
/// Thread-safe: lanes of different apps call it concurrently; one app is
/// only ever written by one lane at a time (`LaneExecutor` claims).
public final class EnhancedUIGuard: @unchecked Sendable {
    /// How long a read value is reused before the next batch reads it again.
    public static let stateLifetime: TimeInterval = 1

    private let control: EnhancedUserInterfaceSwitch?
    private let ownPID: pid_t
    private let clock: ReflowClock
    private let lock = NSLock()
    /// Last value read per app and when.
    private var known: [pid_t: (on: Bool, readAt: TimeInterval)] = [:]
    /// Apps Gio switched off in their running batch.
    private var switchedOff: Set<pid_t> = []
    /// Apps whose restore failed: still off because of Gio.
    private var owed: Set<pid_t> = []

    public init(
        control: EnhancedUserInterfaceSwitch?, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        clock: @escaping ReflowClock = systemReflowClock
    ) {
        self.control = control
        self.ownPID = ownPID
        self.clock = clock
    }

    /// Apps Gio left off and still has to switch back on.
    public var pendingRestores: Set<pid_t> {
        lock.withLock { switchedOff.union(owed) }
    }

    /// Before a frame write of `pid` (lane thread). Idempotent inside a batch.
    public func willWrite(pid: pid_t) {
        guard let control, pid != ownPID else {
            return
        }
        let now = clock()
        enum Step { case done, read, switchOff }
        let step: Step = lock.withLock {
            if switchedOff.contains(pid) {
                return .done
            }
            if owed.contains(pid) {
                switchedOff.insert(pid)
                return .done
            }
            if let entry = known[pid], now - entry.readAt < Self.stateLifetime {
                return entry.on ? .switchOff : .done
            }
            return .read
        }
        switch step {
        case .done:
            return
        case .read:
            // Unreadable counts as off: nothing to restore, nothing to write.
            let on = control.enhancedUserInterface(pid: pid) ?? false
            let previous = lock.withLock { () -> Bool? in
                defer { known[pid] = (on, now) }
                return known[pid]?.on
            }
            if previous != on, on || previous != nil {
                // Once per change, never per batch: pid only.
                GioLog.record(.debug, "enhanced ui pid=\(pid) on=\(on)")
            }
            guard on else {
                return
            }
        case .switchOff:
            break
        }
        // Even a refused write counts as switched off: writing `true` back
        // to an app that kept it on changes nothing.
        _ = control.setEnhancedUserInterface(false, pid: pid)
        lock.withLock { _ = switchedOff.insert(pid) }
    }

    /// The batch of `pid` is over (lane thread): switch it back on.
    public func batchEnded(pid: pid_t) {
        guard lock.withLock({ switchedOff.remove(pid) != nil }) else {
            return
        }
        restore(pid: pid)
    }

    /// Switch a pending app back on (its own lane, or the session's settle).
    public func restore(pid: pid_t) {
        guard let control else {
            return
        }
        let restored = control.setEnhancedUserInterface(true, pid: pid)
        let wasOwed: Bool = lock.withLock {
            switchedOff.remove(pid)
            if restored {
                return owed.remove(pid) != nil
            }
            owed.insert(pid)
            return false
        }
        if !restored {
            GioLog.record(.debug, "enhanced ui restore failed pid=\(pid)")
        } else if wasOwed {
            GioLog.record(.debug, "enhanced ui restored pid=\(pid)")
        }
    }

    /// The app is gone (its pid may be reused).
    public func forget(pid: pid_t) {
        lock.withLock {
            known.removeValue(forKey: pid)
            switchedOff.remove(pid)
            owed.remove(pid)
        }
    }
}
