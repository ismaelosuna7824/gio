@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS

/// The session's event intake: per-app observers attached and detached as
/// apps come and go, and launch / terminate / activation / window events.
/// `SystemWindowObserver` in the app; a fake in tests.
public protocol EventPort: AnyObject {
    /// False when the app refuses (Accessibility not ready yet).
    func attach(pid: pid_t) -> Bool
    func detach(pid: pid_t)
    /// Subscribe to one window's own notifications.
    @discardableResult
    func watch(window element: AXUIElement, pid: pid_t) -> Bool
    func stop()
}

extension SystemWindowObserver: EventPort {}

/// Owns the observers (full rebuild, incremental sync, launch attach with
/// backoff, re-attach on activation) and routes every event on the session
/// queue: motion echoes are dropped before any lookup (PA-04), native-zoom
/// bursts while the zoom is busy, our own write echoes by the echo gate;
/// frame changes that are not ours hold the dim and relayout; appeared,
/// destroyed, minimized and terminated windows go to `DiscoveryService`.
/// Session queue only (events are delivered on main and hop over).
public final class WindowEventRouter: @unchecked Sendable {
    public struct Context {
        /// A fresh port delivering events (on any thread) to the callback.
        public var makePort: (@escaping @Sendable (SystemWindowEvent) -> Void) -> EventPort
        public var runningRegularPIDs: () -> Set<pid_t>
        public var isRegularApplication: (pid_t) -> Bool
        /// The hotkey tap never started (permission may have arrived late).
        public var isTapMissing: () -> Bool
        /// Debounced reflow; `full` also re-enumerates.
        public var scheduleReflow: (Bool) -> Void
        public var reflowAll: () -> Void
        public var requestFocusAdoption: (FocusSource, pid_t, AXUIElement?) -> Void
        /// Another app's windows may now be in front of dimmed ones.
        public var updateDim: () -> Void
        /// A window moved on its own: the dim comes down until the snap-back.
        public var holdDimForDrag: () -> Void
        /// PA-04: pids whose moved/resized events are our own motion writes.
        public var animatingPids: () -> Set<pid_t>
        public var knownWindow: (AXUIElement, pid_t) -> WindowID?
        public var isZoomBusy: (WindowID) -> Bool
        public var forgetZoom: (WindowID) -> Void
        /// Inside the suppression window after our own write (no AX read).
        public var isEchoSuppressed: (WindowID, TimeInterval) -> Bool
        /// The window's current AX frame, nil when unreadable.
        public var frame: (WindowID) -> CGRect?
        public var isEcho: (WindowID, CGRect, TimeInterval) -> Bool
        public var invalidateTrust: (WindowID) -> Void
        public var invalidateTileability: (WindowID) -> Void
        public var title: (AXUIElement) -> String?
        public var registry: () -> WindowRegistry
        /// Operator console line (`[gio] ...`).
        public var console: (String) -> Void
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval

        public init(
            makePort: @escaping (@escaping @Sendable (SystemWindowEvent) -> Void) -> EventPort,
            runningRegularPIDs: @escaping () -> Set<pid_t>, isRegularApplication: @escaping (pid_t) -> Bool,
            isTapMissing: @escaping () -> Bool, scheduleReflow: @escaping (Bool) -> Void,
            reflowAll: @escaping () -> Void,
            requestFocusAdoption: @escaping (FocusSource, pid_t, AXUIElement?) -> Void,
            updateDim: @escaping () -> Void, holdDimForDrag: @escaping () -> Void,
            animatingPids: @escaping () -> Set<pid_t>,
            knownWindow: @escaping (AXUIElement, pid_t) -> WindowID?,
            isZoomBusy: @escaping (WindowID) -> Bool, forgetZoom: @escaping (WindowID) -> Void,
            isEchoSuppressed: @escaping (WindowID, TimeInterval) -> Bool,
            frame: @escaping (WindowID) -> CGRect?,
            isEcho: @escaping (WindowID, CGRect, TimeInterval) -> Bool,
            invalidateTrust: @escaping (WindowID) -> Void, invalidateTileability: @escaping (WindowID) -> Void,
            title: @escaping (AXUIElement) -> String?, registry: @escaping () -> WindowRegistry,
            console: @escaping (String) -> Void, log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.makePort = makePort
            self.runningRegularPIDs = runningRegularPIDs
            self.isRegularApplication = isRegularApplication
            self.isTapMissing = isTapMissing
            self.scheduleReflow = scheduleReflow
            self.reflowAll = reflowAll
            self.requestFocusAdoption = requestFocusAdoption
            self.updateDim = updateDim
            self.holdDimForDrag = holdDimForDrag
            self.animatingPids = animatingPids
            self.knownWindow = knownWindow
            self.isZoomBusy = isZoomBusy
            self.forgetZoom = forgetZoom
            self.isEchoSuppressed = isEchoSuppressed
            self.frame = frame
            self.isEcho = isEcho
            self.invalidateTrust = invalidateTrust
            self.invalidateTileability = invalidateTileability
            self.title = title
            self.registry = registry
            self.console = console
            self.log = log
            self.now = now
        }
    }

    private let context: Context
    private let discovery: DiscoveryService
    private let scheduler: SessionScheduler
    private var port: EventPort?
    private var book = ObservationBook()

    public init(context: Context, discovery: DiscoveryService, scheduler: SessionScheduler) {
        self.context = context
        self.discovery = discovery
        self.scheduler = scheduler
    }

    // MARK: Observers

    /// Full rebuild: only for startup and permission regain. Everyday app
    /// churn goes through the incremental attach/detach below.
    public func rebuild() {
        port?.stop()
        book = ObservationBook()
        port = context.makePort { [weak self] event in
            // Delivered on the main thread; session state lives on the queue.
            guard let self else {
                return
            }
            self.scheduler.async {
                self.handle(event)
            }
        }
        syncObservers()
    }

    /// Reconcile observers with the running set: attach new apps, detach
    /// vanished ones, leave everything else alone. Safety net for missed
    /// launch/terminate notifications; refused apps wait for activation.
    public func syncObservers() {
        guard let port else {
            return
        }
        let plan = book.reconcile(running: context.runningRegularPIDs())
        for pid in plan.detach {
            port.detach(pid: pid)
            book.didDetach(pid)
        }
        var refused: [pid_t] = []
        for pid in plan.attach {
            if port.attach(pid: pid) {
                book.didAttach(pid)
            } else {
                book.didRefuse(pid)
                refused.append(pid)
            }
        }
        if !refused.isEmpty {
            context.console("[gio] observation refused: pid \(refused.map(String.init).joined(separator: ", "))")
            context.log(.warn, "observation refused for \(refused.count) app(s)")
        }
    }

    /// Subscribe a newly registered window to its own notifications.
    public func watch(window element: AXUIElement, pid: pid_t) {
        port?.watch(window: element, pid: pid)
    }

    // MARK: Events

    public func handle(_ event: SystemWindowEvent) {
        switch event.kind {
        case .appLaunched:
            attachLaunchedApp(event.pid, attempt: 0)
        case .appTerminated:
            port?.detach(pid: event.pid)
            book.didDetach(event.pid)
            discovery.appTerminated(event.pid)
        case .appActivated:
            // A previously refused (or missed) app gets another chance now.
            if book.needsAttach(event.pid), let port,
               port.attach(pid: event.pid)
            {
                book.didAttach(event.pid)
            }
            if context.isTapMissing() {
                // Permission may have arrived late: the one activation-time
                // full resync (it retries the tap and rebuilds observers).
                context.scheduleReflow(true)
            }
            context.requestFocusAdoption(.activation, event.pid, nil)
            // Another app's windows may now be in front of dimmed ones.
            context.updateDim()
        case .window(let kind):
            handleWindowEvent(kind, pid: event.pid, element: event.element)
        }
    }

    private func handleWindowEvent(_ kind: WindowEventKind, pid: pid_t, element: AXUIElement?) {
        // Our own animation writes: dropped before the handle lookup.
        if dropsAsMotionEcho(kind, pid: pid, animating: context.animatingPids()) {
            return
        }
        let known = element.flatMap { context.knownWindow($0, pid) }
        // Native zoom: the app animating its own window raises a burst of frame
        // and focus events; they are expected until the zoom was judged.
        if let known, nativeZoomDropsEvent(kind, inFlight: context.isZoomBusy(known)) {
            return
        }
        switch windowEventAction(for: kind, isKnownWindow: known != nil) {
        case .register:
            if let element {
                discovery.registerAppeared(element, pid: pid, attempt: 0)
            }
        case .remove:
            // Exactly this window: no rescan, no debounce.
            if let known {
                discovery.purge([known])
                context.reflowAll()
            }
        case .frameChanged(let invalidate):
            guard let known else {
                return
            }
            // Animation frames raise a burst of events: skip the AX read.
            if context.isEchoSuppressed(known, context.now()) {
                return
            }
            if let observed = context.frame(known),
               context.isEcho(known, observed, context.now())
            {
                return
            }
            // Not our echo: the window moved on its own (drag, app resize).
            // The dim comes down and returns after the snap-back reflow.
            context.holdDimForDrag()
            context.invalidateTrust(known)
            context.forgetZoom(known)
            if invalidate {
                context.invalidateTileability(known)
            }
            context.scheduleReflow(false)
        case .reflow:
            context.scheduleReflow(false)
        case .minimize:
            if let known {
                discovery.applyMinimized(true, to: known)
                context.reflowAll()
            }
        case .restore:
            if let known {
                discovery.applyMinimized(false, to: known)
                context.reflowAll()
            }
        case .updateTitle:
            let registry = context.registry()
            if let known, let element, let title = context.title(element), !title.isEmpty,
               var record = registry.find(known)
            {
                record.title = title
                try? registry.update(record)
            }
        case .adoptFocus:
            context.requestFocusAdoption(.focusChanged, pid, element)
        case .resync:
            context.scheduleReflow(true)
        case .ignore:
            break
        }
    }

    /// Attach one launched app's observer, retrying with backoff while AX
    /// is not ready, then register its windows and reflow. Windows that
    /// appear later arrive through the app-level window-created event.
    private func attachLaunchedApp(_ pid: pid_t, attempt: Int) {
        guard let port,
              context.isRegularApplication(pid),
              book.needsAttach(pid)
        else {
            return
        }
        if port.attach(pid: pid) {
            book.didAttach(pid)
            discovery.appAttached(pid)
        } else if let delay = ObservationRetry.delay(afterFailedAttempt: attempt) {
            scheduler.asyncAfter(delay) { [weak self] in
                self?.attachLaunchedApp(pid, attempt: attempt + 1)
            }
        } else {
            book.didRefuse(pid)
            context.console("[gio] observation refused: pid \(pid)")
            context.log(.warn, "observation refused for launched pid \(pid)")
        }
    }
}
