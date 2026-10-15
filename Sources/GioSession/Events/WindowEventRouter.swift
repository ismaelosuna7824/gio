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
        /// PF-U: Gio's own pid, never observed (rule 4; Gio is `.regular`
        /// while its main window is open).
        public var ownPID: pid_t
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
        /// FI-10: when Gio last wrote the window (`WriteEchoGate.lastWrite`).
        public var lastWrite: (WindowID) -> TimeInterval?
        /// FI-10: a user drag never counts as the app snapping back.
        public var isMouseDown: () -> Bool
        /// FI-11: the frame Gio last wrote (`WriteEchoGate.writtenFrame`).
        public var writtenFrame: (WindowID) -> CGRect?
        /// FI-11: learn a minimum from a size the late re-check found
        /// (written, observed); true when one was learned (the host then
        /// relayouts).
        public var learnLateClamp: (WindowID, CGRect, CGRect) -> Bool

        public init(
            makePort: @escaping (@escaping @Sendable (SystemWindowEvent) -> Void) -> EventPort,
            ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
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
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            lastWrite: @escaping (WindowID) -> TimeInterval?,
            isMouseDown: @escaping () -> Bool,
            writtenFrame: @escaping (WindowID) -> CGRect?,
            learnLateClamp: @escaping (WindowID, CGRect, CGRect) -> Bool
        ) {
            self.makePort = makePort
            self.ownPID = ownPID
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
            self.lastWrite = lastWrite
            self.isMouseDown = isMouseDown
            self.writtenFrame = writtenFrame
            self.learnLateClamp = learnLateClamp
        }
    }

    private let context: Context
    private let discovery: DiscoveryService
    private let scheduler: SessionScheduler
    private var port: EventPort?
    private var book = ObservationBook()
    /// FI-10: apps restoring their own frame right after Gio wrote it.
    private var snapBacks = SnapBackBook()
    /// FI-11: windows with a re-check pending for when their echo window ends.
    private var lateChecks: Set<WindowID> = []
    /// FI-11: the re-check runs this long after the echo window ended.
    static let lateCheckMargin: TimeInterval = 0.05

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
            // PF-02: stamped at delivery, so the open line can tell the
            // wait for the queue apart from the registration work.
            let deliveredAt = self.context.now()
            self.scheduler.async {
                self.handle(event, deliveredAt: deliveredAt)
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
        var running = context.runningRegularPIDs()
        running.remove(context.ownPID)
        let plan = book.reconcile(running: running)
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

    /// FI-10: a purged or re-registered window starts a new snap-back count.
    public func forgetSnapBacks(_ id: WindowID) {
        snapBacks.forget(id)
    }

    // MARK: Events

    /// `deliveredAt`: when the event reached the main thread (nil: unknown).
    public func handle(_ event: SystemWindowEvent, deliveredAt: TimeInterval? = nil) {
        switch event.kind {
        case .appLaunched:
            // NW-06: before the attach, whose scan may register its windows.
            discovery.appLaunched(event.pid)
            attachLaunchedApp(event.pid, attempt: 0)
        case .appTerminated:
            port?.detach(pid: event.pid)
            book.didDetach(event.pid)
            discovery.appTerminated(event.pid)
        case .appActivated:
            // A previously refused (or missed) app gets another chance now.
            if event.pid != context.ownPID, book.needsAttach(event.pid), let port,
               port.attach(pid: event.pid)
            {
                book.didAttach(event.pid)
            }
            if context.isTapMissing() {
                // Permission may have arrived late: the one activation-time
                // full resync (it retries the tap and rebuilds observers).
                context.scheduleReflow(true)
            }
            // NW-06: a window placed moments ago may take the user to its
            // workspace now; before adoption, which then focuses it there.
            discovery.appActivated(event.pid)
            context.requestFocusAdoption(.activation, event.pid, nil)
            // Another app's windows may now be in front of dimmed ones.
            context.updateDim()
        case .window(let kind):
            handleWindowEvent(kind, pid: event.pid, element: event.element, deliveredAt: deliveredAt)
        }
    }

    private func handleWindowEvent(
        _ kind: WindowEventKind, pid: pid_t, element: AXUIElement?, deliveredAt: TimeInterval?
    ) {
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
                discovery.registerAppeared(element, pid: pid, deliveredAt: deliveredAt)
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
            let now = context.now()
            if context.isEchoSuppressed(known, now) {
                // FI-11: an app that applies its own size after Gio's
                // read-back raises its resize in here; look once more when
                // the echo window ends. Moves (every scroll raises them) are
                // not re-checked: a late clamp only follows a size write.
                if kind == .resized {
                    scheduleLateCheck(known)
                }
                return
            }
            let observed = context.frame(known)
            if let observed, context.isEcho(known, observed, now) {
                return
            }
            // WC-11: a background tab following its group, or a tab dragged
            // out to its own window (placed as an arrival).
            if let observed, discovery.tabWindowMoved(known, frame: observed) {
                return
            }
            let record = context.registry().find(known)
            if record?.floatReason == .appControlled {
                // FI-10: the app owns this frame now; nothing is written back.
                context.updateDim()
                return
            }
            let verdict = snapBacks.note(
                known, at: now, lastWrite: context.lastWrite(known), dragging: context.isMouseDown()
            )
            if case .yield(let count) = verdict, let record {
                yieldToApp(record, snapBacks: count)
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
                discovery.titleChanged(known)
            }
        case .adoptFocus:
            context.requestFocusAdoption(.focusChanged, pid, element)
        case .resync:
            context.scheduleReflow(true)
        case .ignore:
            break
        }
    }

    /// FI-11: one re-check per window, `lateCheckMargin` after its echo
    /// window ends (`WriteEchoGate`: the last write plus `suppression`).
    private func scheduleLateCheck(_ id: WindowID) {
        guard !lateChecks.contains(id), let written = context.lastWrite(id) else {
            return
        }
        lateChecks.insert(id)
        let delay = max(0, written + WriteEchoGate.suppression - context.now()) + Self.lateCheckMargin
        scheduler.asyncAfter(delay) { [weak self] in
            self?.runLateCheck(id)
        }
    }

    /// FI-11: a window still at the size Gio wrote is left alone (a position
    /// alone is a parking or menu-bar clamp). Otherwise a clamp the app
    /// applied late is learned (the host relayouts with it); any other size
    /// is the app's own change, laid out again like any non-echo event and
    /// counted as a snap-back (FI-10), so an unlearnable one cannot loop.
    /// A purged or yielded window is dropped; a window Gio wrote again
    /// meanwhile waits for that write's echo window.
    private func runLateCheck(_ id: WindowID) {
        lateChecks.remove(id)
        guard let record = context.registry().find(id), record.floatReason != .appControlled else {
            return
        }
        let now = context.now()
        if context.isEchoSuppressed(id, now) {
            scheduleLateCheck(id)
            return
        }
        guard let written = context.writtenFrame(id), let observed = context.frame(id),
              lateFrameResized(written: written, observed: observed)
        else {
            return
        }
        let dragging = context.isMouseDown()
        if !dragging, context.learnLateClamp(id, written, observed) {
            return
        }
        context.log(.debug, "late frame change id=\(id.pid):\(id.elementID) app=\(record.application)")
        let verdict = snapBacks.note(id, at: now, lastWrite: context.lastWrite(id), dragging: dragging)
        if case .yield(let count) = verdict {
            yieldToApp(record, snapBacks: count)
            return
        }
        context.invalidateTrust(id)
        context.forgetZoom(id)
        context.scheduleReflow(false)
    }

    /// FI-10: the app restored its own frame `snapBacks` times right after
    /// Gio wrote it: it floats as `appControlled` (still a member of its
    /// workspace) and no pass writes it again; one pass lets the neighbours
    /// close its gap.
    private func yieldToApp(_ record: ManagedWindow, snapBacks: Int) {
        guard (try? context.registry().setFloating(.appControlled, for: record.id)) != nil else {
            return
        }
        context.log(
            .warn,
            "window yields to app id=\(record.id.pid):\(record.id.elementID) app=\(record.application) snapBacks=\(snapBacks)"
        )
        context.invalidateTrust(record.id)
        context.forgetZoom(record.id)
        context.scheduleReflow(false)
    }

    /// Attach one launched app's observer, retrying with backoff while AX
    /// is not ready, then register its windows and reflow. Windows that
    /// appear later arrive through the app-level window-created event.
    private func attachLaunchedApp(_ pid: pid_t, attempt: Int) {
        guard let port,
              pid != context.ownPID,
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
