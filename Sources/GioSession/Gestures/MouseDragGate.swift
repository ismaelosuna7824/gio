import CoreGraphics
import Foundation
import GioCore

/// MD-01: what the session gets from a modifier drag the gate took.
public enum MouseDragSignal: Equatable, Sendable {
    case begin(MouseDragKind, WindowID, CGPoint)
    case move(CGPoint)
    case end(CGPoint)
}

/// MD-01: the event tap's side of the mouse drags. `handle` runs on the tap
/// thread for every mouse button event and answers at once whether the tap
/// swallows it: a press with exactly the drag modifier over a tiled window
/// (`publish`, the last pass's frames) that is the frontmost window there
/// starts a drag, and its drags and release are swallowed with it so the
/// app never sees half a click. Everything else passes through. The signals
/// go to the session queue through one scheduled drain per burst (latest
/// pointer position wins); session state is never touched here.
public final class MouseDragGate: @unchecked Sendable {
    /// Guards every field below (tap thread vs session queue).
    private let lock = NSLock()
    private var settings = MouseDragSettings(move: false, resize: false, modifiers: [])
    private var frames: [WindowID: CGRect] = [:]
    private var active: MouseButton?
    private var pending: [MouseDragSignal] = []
    private var drainScheduled = false
    private let scheduler: SessionScheduler
    private let ownPID: pid_t
    private let topWindowPID: @Sendable (CGPoint) -> pid_t?
    private let deliver: ([MouseDragSignal]) -> Void

    /// `topWindowPID` (tap thread) names the owner of the frontmost window
    /// at a point; `deliver` runs on the session queue.
    public init(
        scheduler: SessionScheduler, ownPID: pid_t, topWindowPID: @escaping @Sendable (CGPoint) -> pid_t?,
        deliver: @escaping ([MouseDragSignal]) -> Void
    ) {
        self.scheduler = scheduler
        self.ownPID = ownPID
        self.topWindowPID = topWindowPID
        self.deliver = deliver
    }

    /// Session queue (config applied).
    public func configure(_ settings: MouseDragSettings) {
        lock.lock()
        self.settings = settings
        lock.unlock()
    }

    /// Session queue, after every pass: the tiled windows a drag may take
    /// (shown, on a scrolling strip; Cocoa frames).
    public func publish(_ frames: [WindowID: CGRect]) {
        lock.lock()
        self.frames = frames
        lock.unlock()
    }

    /// Tap thread. True: the tap swallows the event.
    public func handle(_ event: MouseButtonEvent) -> Bool {
        lock.lock()
        switch event.phase {
        case .down:
            guard active == nil, let kind = mouseDragKind(for: event, settings: settings),
                  frames.values.contains(where: { $0.contains(event.location) })
            else {
                lock.unlock()
                return false
            }
            let candidates = frames
            lock.unlock()
            // One WindowServer query, only for a modifier press over a tile.
            guard let window = hoverTarget(
                at: event.location, frames: candidates, topWindowPID: topWindowPID(event.location), ownPID: ownPID
            ) else {
                return false
            }
            lock.lock()
            guard active == nil else {
                lock.unlock()
                return false
            }
            active = event.button
            post(.begin(kind, window, event.location))
            return true
        case .dragged:
            guard active == event.button else {
                lock.unlock()
                return false
            }
            if case .move = pending.last {
                pending.removeLast()
            }
            post(.move(event.location))
            return true
        case .up:
            guard active == event.button else {
                lock.unlock()
                return false
            }
            active = nil
            post(.end(event.location))
            return true
        }
    }

    /// Called with `lock` held; releases it.
    private func post(_ signal: MouseDragSignal) {
        pending.append(signal)
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule {
            scheduler.async { [weak self] in
                self?.drain()
            }
        }
    }

    private func drain() {
        lock.lock()
        let signals = pending
        pending.removeAll(keepingCapacity: true)
        drainScheduled = false
        lock.unlock()
        if !signals.isEmpty {
            deliver(signals)
        }
    }
}
