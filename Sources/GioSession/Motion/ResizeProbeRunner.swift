import CoreGraphics
import Foundation
import GioCore

/// Diagnostics: for each growing animation, polls the WindowServer bounds of
/// that window only until they match the requested size or 1.5 s pass, and
/// logs `resize latency`. The window is found by pid + frame (FI-05 rule);
/// unresolvable or ambiguous windows are skipped. Each probe is one strict
/// 8 ms scheduler timer that ends itself. PA-15d: a diagnostic, so it runs
/// only while `isEnabled` (debug logging). Session queue only. Logs carry
/// app names, never titles.
public final class ResizeProbeRunner: @unchecked Sendable {
    public struct Context {
        /// PA-15d: probes start only while this is true (debug logging).
        public var isEnabled: () -> Bool
        public var isShuttingDown: () -> Bool
        /// The WindowServer window of each managed frame (one query for all).
        public var matchWindows: ([WindowID: CGRect]) -> [WindowID: SnapshotMatch]
        /// Current WindowServer size of a window, nil when unlisted.
        public var windowServerSize: (UInt32) -> CGSize?
        /// The window's AX size attribute is settable.
        public var isSizeSettable: (WindowID) -> Bool
        public var appName: (pid_t) -> String
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval

        public init(
            isEnabled: @escaping () -> Bool,
            isShuttingDown: @escaping () -> Bool,
            matchWindows: @escaping ([WindowID: CGRect]) -> [WindowID: SnapshotMatch],
            windowServerSize: @escaping (UInt32) -> CGSize?,
            isSizeSettable: @escaping (WindowID) -> Bool,
            appName: @escaping (pid_t) -> String,
            log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.isEnabled = isEnabled
            self.isShuttingDown = isShuttingDown
            self.matchWindows = matchWindows
            self.windowServerSize = windowServerSize
            self.isSizeSettable = isSizeSettable
            self.appName = appName
            self.log = log
            self.now = now
        }
    }

    private struct Probe {
        let size: CGSize
        let started: CGSize?
        let timer: SessionTimer
    }

    private let context: Context
    private let scheduler: SessionScheduler
    private var probes: [WindowID: Probe] = [:]
    /// The sizes each window already reached (`first=` in the log).
    private var history = ResizeSizeHistory()
    /// Windows the probe learned to ignore (fixed size, not settable).
    private var gate = ResizeProbeGate()

    public init(context: Context, scheduler: SessionScheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    /// Live probes (tests).
    var activeCount: Int {
        probes.count
    }

    /// A purged window: forget that it ignored an earlier probe.
    public func forget(_ id: WindowID) {
        gate.forget(id)
    }

    /// Probe the growing animations among `animations`; `frames` gives the
    /// frame each window is matched at in the WindowServer.
    public func probe(of animations: [WindowAnimation], frames: (WindowAnimation) -> CGRect) {
        let growing = animations.filter {
            $0.duration > 0
                && ($0.to.width - $0.from.width > ResizeProbeLimits.tolerance
                    || $0.to.height - $0.from.height > ResizeProbeLimits.tolerance)
        }
        guard !growing.isEmpty, context.isEnabled() else {
            return
        }
        let managed = Dictionary(growing.map { ($0.id, frames($0)) }, uniquingKeysWith: { $1 })
        let matches = context.matchWindows(managed)
        for animation in growing {
            guard case .matched(let windowID)? = matches[animation.id] else {
                continue
            }
            if let live = probes[animation.id], live.size == animation.to.size {
                continue
            }
            // Only windows that can be resized and are not already that size:
            // anything else could only log a `wsMs=timeout` that says nothing.
            let current = context.windowServerSize(windowID)
            let settable = context.isSizeSettable(animation.id)
            guard gate.shouldStart(
                animation.id, current: current, requested: animation.to.size, sizeSettable: settable
            ) else {
                continue
            }
            start(id: animation.id, requested: animation.to.size, windowID: windowID, started: current)
        }
    }

    private func start(id: WindowID, requested: CGSize, windowID: UInt32, started: CGSize?) {
        probes[id]?.timer.cancel()
        let began = context.now()
        let timer = scheduler.makeStrictTimer(start: 0, interval: 0.008) { [weak self] in
            self?.poll(id: id, requested: requested, windowID: windowID, started: started, began: began)
        }
        probes[id] = Probe(size: requested, started: started, timer: timer)
    }

    private func poll(id: WindowID, requested: CGSize, windowID: UInt32, started: CGSize?, began: TimeInterval) {
        guard !context.isShuttingDown() else {
            return
        }
        let elapsed = context.now() - began
        let decision = resizeProbeDecision(
            requested: requested, observed: context.windowServerSize(windowID), elapsed: elapsed
        )
        guard decision != .pending else {
            return
        }
        probes[id]?.timer.cancel()
        probes[id] = nil
        // A window that never left its size is not slow to repaint, it
        // does not resize: remember that and stay quiet.
        if decision == .timeout,
           gate.recordTimeout(id, started: started, observed: context.windowServerSize(windowID))
        {
            return
        }
        let first = history.recordIsFirst(id, size: requested)
        context.log(
            .info,
            resizeLatencyLine(id: id, app: context.appName(id.pid), size: requested, result: decision, first: first)
        )
    }
}
