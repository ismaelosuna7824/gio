@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import GioUI

/// The unified Gio session: persistent registry, workspaces, displays and
/// actuator behind one serial queue, serving IPC, AX events, display
/// changes and hotkeys. All mutations and reflows happen on `queue` —
/// callers hop on (async from UI/tap, sync from the IPC thread) and never
/// touch state directly. Nesting sync calls deadlocks: don't.
///
/// `@unchecked Sendable`: all session state mutates on `queue`; start/stop
/// run once on the main thread. Weak captures in `@Sendable` closures rely
/// on this discipline — review before adding shared state.
final class SessionHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "gio.session")
    private var session = CommandSession()
    private var displays = DisplayManager()
    private var actuator: AXWindowActuator?
    private var server: IPCServer?
    private let instanceLock = SingleInstanceLock()
    private var eventObserver: SystemWindowObserver?
    private var hotkeyTap: HotkeyTap?
    private var displayObserver: NSObjectProtocol?
    private var pendingReflow: DispatchWorkItem?
    private var nextElementID: UInt64 = 0
    private var observationBook = ObservationBook()
    private var echoGate = WriteEchoGate()
    private var pendingFull = false
    private var tileability = TileabilityCache()
    private var fullscreenRecords: [WindowID: FullscreenRecord] = [:]
    private var visibleFrames: [DisplayID: CGRect] = [:]
    private let dispatcher = HotkeyDispatcher()
    private var isShuttingDown = false
    private var reflowDeferral = ReflowDeferral()

    /// UI hook, always invoked on the main thread.
    var onSummonLauncher: (() -> Void)?

    // MARK: - Lifecycle

    /// Starts everything. Returns an error message instead of starting when
    /// another instance holds the lock or the socket cannot bind.
    func start() -> String? {
        guard instanceLock.acquire(path: defaultLockPath()) else {
            return "another Gio instance is running"
        }
        let (config, configMessages) = loadGioConfig()
        session.config = config
        for message in configMessages {
            print("[gio] config: \(message)")
        }
        if !hasAXPermission() {
            print("[gio] requesting Accessibility permission…")
            _ = requestAXPermission()
        }
        let server = IPCServer(socketPath: defaultSocketPath()) { [weak self] argv in
            guard let self else {
                return IPCResponse(ok: false, error: "shutting down")
            }
            return self.queue.sync {
                self.handleIPC(argv)
            }
        }
        do {
            try server.start()
        } catch {
            return "cannot serve IPC: \(error)"
        }
        self.server = server
        GioLog.record(.info, "session started")
        queue.sync {
            self.initialSync()
        }
        watchDisplays()
        queue.sync {
            self.rebuildEventObservation()
        }
        startTap()
        return nil
    }

    /// Gio is exiting (Quit, SIGTERM/SIGINT/SIGHUP): stop laying out, bring
    /// every parked or off-screen window back on screen through the
    /// reconciler, release the socket and lock. Idempotent and synchronous,
    /// so it is safe to call from both the terminate hook and a signal.
    func shutdown() {
        queue.sync {
            guard !isShuttingDown else {
                return
            }
            isShuttingDown = true
            pendingReflow?.cancel()
            restoreOffscreenWindows(session.registry.managedWindows().filter { !$0.isMinimized }.map(\.id))
        }
        server?.stop()
        instanceLock.release()
    }

    private func restoreOffscreenWindows(_ ids: [WindowID]) {
        guard let actuator, !ids.isEmpty else {
            return
        }
        WindowReconciler(actuator: actuator)
            .restoreOffscreen(ids: ids, displays: restoreDisplays())
    }

    // MARK: - IPC

    private func handleIPC(_ argv: [String]) -> IPCResponse {
        let parsed = parseCLICommand(argv)
        let response = dispatchIPC(argv, session: &session)
        if case .success(let command) = parsed {
            switch command {
            case .reload:
                reapplyRules()
                reflowAll()
            case .focus, .move, .workspace:
                reflowAll()
            default:
                break
            }
        }
        return response
    }

    // MARK: - Sync

    private func mainHeight() -> CGFloat {
        NSScreen.main?.frame.height ?? 1169
    }

    private func initialSync() {
        if actuator == nil {
            actuator = AXWindowActuator(displayHeight: mainHeight())
        }
        enumerateAndPlace()
        syncDisplays()
        // Leftovers of a crashed session: windows that will not be tiled
        // (floating, excluded) may still sit parked off-screen. Tiled ones
        // are re-placed by the first reflow.
        _ = tileableModes()
        restoreOffscreenWindows(
            session.registry.managedWindows()
                .filter { $0.mode != .tiled && !$0.isMinimized }
                .map(\.id)
        )
        reflowAll()
    }

    /// Enumerate, register arrivals (rules decide mode and workspace),
    /// refresh handles. Identity is stable across scans: retained handles
    /// matched with `CFEqual` reuse their IDs (and refresh metadata);
    /// only genuinely new windows get fresh IDs and placed columns.
    /// Add-only: disappearance is handled by reaping dead pids below,
    /// never by absence alone.
    ///
    /// `onlyPID` restricts the scan to one process (a freshly launched app):
    /// the dead-pid reap is skipped then, since absence from a partial
    /// scan proves nothing.
    private func enumerateAndPlace(onlyPID: pid_t? = nil) {
        guard let found = try? discoverSystemWindows(onlyPID: onlyPID) else {
            return
        }
        let flip = AXVerticalFlip(displayHeight: mainHeight())
        var liveIDs = Set<WindowID>()
        var focusCandidates: [FocusCandidate] = []
        // Minimized windows are candidates too: they stay registered (and
        // keep their column) but sit out of the layout.
        for candidate in found.windows + found.floating {
            if let known = actuator?.id(
                matching: candidate.element, pid: candidate.window.pid
            ) {
                liveIDs.insert(known)
                if var record = session.registry.find(known) {
                    if !candidate.window.isMinimized {
                        record.frame = flip.toCocoa(candidate.window.frame)
                    }
                    if let title = candidate.window.title, !title.isEmpty {
                        record.title = title
                    }
                    try? session.registry.update(record)
                    // A missed minimize/deminimize event heals here.
                    if record.isMinimized != candidate.window.isMinimized {
                        applyMinimized(candidate.window.isMinimized, to: known)
                    }
                }
                focusCandidates.append(FocusCandidate(
                    id: known, isFocused: candidate.window.isFocused,
                    isMinimized: candidate.window.isMinimized
                ))
                continue
            }
            liveIDs.insert(registerNew(candidate))
        }
        // Clicks change macOS focus behind our back: adopt the observed
        // focus instead of fighting it on the next reflow. Every app reports
        // a focused window; only the frontmost app's is the user's.
        if let focusedID = adoptableFocus(
            among: focusCandidates,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) {
            adoptFocus(focusedID)
        }
        if onlyPID == nil {
            reapDeadPids(live: liveIDs)
        }
        // Fallback for destroyed events whose element match failed: windows
        // of a fully-read pid that the scan no longer lists are gone.
        purge(vanishedWindowIDs(
            registered: session.registry.managedWindows(),
            scannedPIDs: found.completePIDs,
            present: liveIDs
        ))
    }

    private func applyMinimized(_ minimized: Bool, to id: WindowID) {
        if minimized {
            minimizeWindow(id, registry: session.registry, manager: &session.manager)
        } else {
            restoreWindow(id, registry: session.registry, manager: &session.manager)
        }
    }

    /// Config reload: rule-owned floats follow the new rules. Workspace
    /// assignment is not re-applied (rules place windows at arrival only).
    private func reapplyRules() {
        for change in reevaluateRules(session.config.rules, windows: session.registry.managedWindows()) {
            switch change {
            case .float(let id):
                try? session.registry.setFloating(.rule, for: id)
            case .tile(let id):
                try? session.registry.setMode(.tiled, for: id)
                tileability.invalidate(id)
            }
        }
    }

    /// Register a genuinely new window: fresh ID, retained AX handles,
    /// rules and admission decide mode and workspace, a new column on the
    /// target workspace, and a per-window observer subscription.
    @discardableResult
    private func registerNew(_ candidate: DiscoveredSystemWindow) -> WindowID {
        nextElementID += 1
        let id = WindowID(pid: candidate.window.pid, elementID: nextElementID)
        actuator?.register(
            elementID: id.elementID, pid: id.pid,
            element: candidate.element, appElement: candidate.appElement
        )
        var window = ManagedWindow(
            id: id, pid: candidate.window.pid,
            application: candidate.window.appName,
            title: candidate.window.title ?? "",
            frame: AXVerticalFlip(displayHeight: mainHeight()).toCocoa(candidate.window.frame),
            mode: .tiled,
            isMinimized: candidate.window.isMinimized
        )
        let outcome = evaluateRules(session.config.rules, app: window.application)
        window.mode = outcome.mode ?? .tiled
        if outcome.mode == .floating {
            window.floatReason = .rule
        } else if let admitted = candidate.floatReason {
            // Discovery floated it (dialog, panel, fixed size): managed
            // and visible, never moved by the layout.
            window.mode = .floating
            window.floatReason = admitted
        }
        tileability.invalidate(id)
        try? session.registry.register(window)
        if let wanted = outcome.workspace,
           WorkspaceManager.range.contains(wanted),
           wanted != session.manager.current
        {
            var dest = session.manager.workspace(wanted)!
            var column = Column(
                id: ColumnID((dest.columns.map(\.id.rawValue).max() ?? 0) + 1),
                width: 0, windows: [id]
            )
            column.focusedWindowIndex = 0
            dest.columns.append(column)
            if !window.isMinimized {
                dest.focusedColumn = dest.columns.count - 1
                dest.focusedWindow = id
            }
            session.manager.update(dest)
        } else {
            var current = session.manager.currentWorkspace()
            var column = Column(
                id: ColumnID((current.columns.map(\.id.rawValue).max() ?? 0) + 1),
                width: 0, windows: [id]
            )
            column.focusedWindowIndex = 0
            current.columns.append(column)
            if !window.isMinimized {
                current.focusedColumn = current.columns.count - 1
                current.focusedWindow = id
            }
            session.manager.update(current)
        }
        eventObserver?.watch(window: candidate.element, pid: candidate.window.pid)
        return id
    }

    /// Remove records whose process is gone (proof, not absence) from the
    /// registry and every workspace. Present-but-unlisted windows survive:
    /// enumeration gaps must never read as deaths.
    private func reapDeadPids(live: Set<WindowID>) {
        let livePIDs = Set(live.map(\.pid))
        let dead = session.registry.managedWindows()
            .map(\.id)
            .filter { !livePIDs.contains($0.pid) && NSRunningApplication(processIdentifier: $0.pid) == nil }
        guard !dead.isEmpty else {
            return
        }
        purge(dead)
    }

    /// Forget windows everywhere: registry, every workspace, tileability
    /// cache, fullscreen records and the actuator's AX handles.
    private func purge(_ ids: [WindowID]) {
        guard !ids.isEmpty else {
            return
        }
        let idSet = Set(ids)
        for id in ids.sorted() {
            session.registry.remove(id)
            tileability.invalidate(id)
            echoGate.forget(id)
            fullscreenRecords.removeValue(forKey: id)
            actuator?.forget(elementID: id.elementID)
        }
        for index in WorkspaceManager.range {
            guard var workspace = session.manager.workspace(index) else {
                continue
            }
            let before = workspace
            workspace.stripWindows(idSet)
            if workspace != before {
                session.manager.update(workspace)
            }
        }
    }

    private func syncDisplays() {
        let snapshot = snapshotDisplayList()
        let seen = Set(snapshot.map(\.id))
        for display in snapshot {
            visibleFrames[display.id] = display.visibleFrame
            if displays.display(display.id) == nil {
                displays.connect(display.id, frame: display.frame, workspace: WorkspaceID(UInt64(session.manager.current)))
            } else {
                displays.connect(display.id, frame: display.frame, workspace: displays.display(display.id)!.workspace)
            }
        }
        for known in displays.allDisplays().map(\.id) where !seen.contains(known) {
            displays.disconnect(known)
            visibleFrames.removeValue(forKey: known)
        }
        if let main = NSScreen.main {
            actuator?.updateDisplayHeight(main.frame.height)
        }
    }

    // MARK: - Reflow

    private func engine() -> ScrollableLayoutEngine {
        // Rebuilt per pass so config reloads apply instantly.
        ScrollableLayoutEngine(config: session.config.makeLayoutConfig(
            viewportWidth: NSScreen.main?.visibleFrame.width ?? 1800
        ))
    }

    private func tileableModes() -> [WindowID: WindowMode] {
        // Verdicts are cached per window; a failed probe makes the window
        // floating(notResizable) in the registry instead of dropping it.
        reconcileTileability(registry: session.registry, cache: &tileability) { [actuator] id in
            guard let element = actuator?.element(for: id) else {
                return false
            }
            return axIsTileable(element)
        }
    }

    /// Adopt `id` as the session focus (current workspace). True when the
    /// focus changed.
    @discardableResult
    private func adoptFocus(_ id: WindowID) -> Bool {
        let current = session.manager.currentWorkspace()
        guard let adopted = adoptingFocus(id, in: current), adopted != current else {
            return false
        }
        session.manager.update(adopted)
        return true
    }

    /// Would laying out the current workspace scroll the viewport (focused
    /// column hidden, or offset out of bounds)? Decides whether a click on
    /// an already-visible column needs any reflow at all.
    private func viewportNeedsScroll() -> Bool {
        let modes = tileableModes()
        for display in displays.allDisplays() {
            guard let workspace = session.manager.workspace(Int(display.workspace.rawValue)),
                  let planned = try? planDisplayLayout(
                      workspace: workspace, modes: modes, engine: engine(),
                      viewport: visibleFrames[display.id] ?? display.frame,
                      display: display.frame, otherDisplays: []
                  )
            else {
                continue
            }
            if planned.workspace.viewportOffset != workspace.viewportOffset {
                return true
            }
        }
        return false
    }

    /// Every write funnels through here. While a mouse button is down the
    /// reflow waits (polling every 50 ms, coalesced) so nothing moves under
    /// the cursor; a user's manual drag is therefore not fought, and the
    /// window snaps back to its column after release.
    private func reflowAll() {
        guard !isShuttingDown else {
            return
        }
        switch reflowDeferral.request(mouseDown: NSEvent.pressedMouseButtons != 0) {
        case .apply:
            performReflow()
        case .poll(let delay):
            scheduleDeferredReflow(after: delay)
        case .alreadyPolling:
            break
        }
    }

    private func scheduleDeferredReflow(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isShuttingDown else {
                return
            }
            switch self.reflowDeferral.poll(mouseDown: NSEvent.pressedMouseButtons != 0) {
            case .apply:
                self.performReflow()
            case .poll(let next):
                self.scheduleDeferredReflow(after: next)
            case .alreadyPolling:
                break
            }
        }
    }

    private func performReflow() {
        guard let actuator else {
            return
        }
        let reconciler = WindowReconciler(actuator: actuator)
        let modes = tileableModes()
        for display in displays.allDisplays() {
            guard let workspace = session.manager.workspace(Int(display.workspace.rawValue)) else {
                continue
            }
            let visible = visibleFrames[display.id] ?? display.frame
            guard let planned = try? planDisplayLayout(
                workspace: workspace, modes: modes, engine: engine(),
                viewport: visible, display: display.frame,
                otherDisplays: displays.allDisplays().filter { $0.id != display.id }.map(\.frame)
            ) else {
                continue
            }
            let plan = planned.plan
            // Never let the reconciler raise a minimized window.
            let focused = workspace.focusedWindow.flatMap {
                session.registry.find($0)?.isMinimized == true ? nil : $0
            }
            let report = reconciler.reconcile(
                frames: plan.visible, parked: plan.parked,
                focused: focused, currentlyFocused: focused
            )
            GioLog.record(
                .info,
                "reflow applied=\(report.applied.count) parked=\(report.parked.count) already=\(report.alreadyCorrect.count) failed=\(report.failed.count)"
            )
            // Our writes echo back as moved/resized events: remember them
            // (parked ones too, so they never retrigger a reflow).
            echoGate.recordApplied(
                plan.visible.merging(plan.parked.mapValues(\.frame)) { first, _ in first },
                at: ProcessInfo.processInfo.systemUptime
            )
            session.manager.update(planned.workspace)
            displays.updateViewport(
                Viewport(offset: planned.layout.viewportOffset, width: visible.width), for: display.id
            )
        }
    }

    /// Debounced reflow. `full` also re-enumerates windows (resync); a
    /// light one only re-lays out what is registered. A pending full
    /// request is never downgraded by a later light one.
    private func scheduleReflow(full: Bool = true) {
        pendingFull = pendingFull || full
        pendingReflow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            let wantsFull = self.pendingFull
            self.pendingFull = false
            if wantsFull {
                self.resyncAndReflow()
            } else {
                self.reflowAll()
            }
        }
        pendingReflow = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func resyncAndReflow() {
        if let main = NSScreen.main {
            actuator?.updateDisplayHeight(main.frame.height)
        }
        // The tap starts once at launch; if permission arrived later it
        // stayed deaf — retry here so granting + any window event heals it
        // without relaunching.
        if hotkeyTap == nil {
            startTap()
            if hotkeyTap != nil {
                // Permission regained: observers built without it are dead,
                // and every verdict is stale. The one full rebuild.
                tileability.invalidateAll()
                rebuildEventObservation()
            }
        }
        // Tileability verdicts are invalidated per window by resize events
        // and on registration, not on every resync.
        enumerateAndPlace()
        syncObservers()
        reflowAll()
    }

    private func runningRegularPIDs() -> Set<pid_t> {
        Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier)
        )
    }

    // MARK: - Observers

    /// Full rebuild: only for startup and permission regain. Everyday app
    /// churn goes through the incremental attach/detach below.
    private func rebuildEventObservation() {
        eventObserver?.stop()
        observationBook = ObservationBook()
        eventObserver = SystemWindowObserver { [weak self] event in
            // Delivered on the main thread; session state lives on `queue`.
            guard let self else {
                return
            }
            self.queue.async {
                self.handle(event)
            }
        }
        syncObservers()
    }

    /// Reconcile observers with the running set: attach new apps, detach
    /// vanished ones, leave everything else alone. Safety net for missed
    /// launch/terminate notifications; refused apps wait for activation.
    private func syncObservers() {
        guard let observer = eventObserver else {
            return
        }
        let plan = observationBook.reconcile(running: runningRegularPIDs())
        for pid in plan.detach {
            observer.detach(pid: pid)
            observationBook.didDetach(pid)
        }
        var refused: [pid_t] = []
        for pid in plan.attach {
            if observer.attach(pid: pid) {
                observationBook.didAttach(pid)
            } else {
                observationBook.didRefuse(pid)
                refused.append(pid)
            }
        }
        if !refused.isEmpty {
            print("[gio] observation refused: pid \(refused.map(String.init).joined(separator: ", "))")
            GioLog.record(.warn, "observation refused for \(refused.count) app(s)")
        }
    }

    private func handle(_ event: SystemWindowEvent) {
        switch event.kind {
        case .appLaunched:
            attachLaunchedApp(event.pid, attempt: 0)
        case .appTerminated:
            handleTerminated(event.pid)
        case .appActivated:
            // A previously refused (or missed) app gets another chance now.
            if observationBook.needsAttach(event.pid), let observer = eventObserver,
               observer.attach(pid: event.pid)
            {
                observationBook.didAttach(event.pid)
            }
            if hotkeyTap == nil {
                // Permission may have arrived late: the one activation-time
                // full resync (it retries the tap and rebuilds observers).
                scheduleReflow()
            }
            adoptFocusedWindow(of: event.pid)
        case .window(let kind):
            handleWindowEvent(kind, pid: event.pid, element: event.element)
        }
    }

    private func handleWindowEvent(_ kind: WindowEventKind, pid: pid_t, element: AXUIElement?) {
        let known = element.flatMap { actuator?.id(matching: $0, pid: pid) }
        switch windowEventAction(for: kind, isKnownWindow: known != nil) {
        case .register:
            if let element {
                registerAppearedWindow(element, pid: pid, attempt: 0)
            }
        case .remove:
            // Exactly this window: no rescan, no debounce.
            if let known {
                purge([known])
                reflowAll()
            }
        case .frameChanged(let invalidate):
            guard let known else {
                return
            }
            if let observed = try? actuator?.frame(of: known),
               echoGate.isEcho(known, observed: observed, at: ProcessInfo.processInfo.systemUptime)
            {
                return
            }
            if invalidate {
                tileability.invalidate(known)
            }
            scheduleReflow(full: false)
        case .reflow:
            scheduleReflow(full: false)
        case .minimize:
            if let known {
                minimizeWindow(known, registry: session.registry, manager: &session.manager)
                reflowAll()
            }
        case .restore:
            if let known {
                restoreWindow(known, registry: session.registry, manager: &session.manager)
                reflowAll()
            }
        case .updateTitle:
            if let known, let element, let title = axTitle(of: element), !title.isEmpty,
               var record = session.registry.find(known)
            {
                record.title = title
                try? session.registry.update(record)
            }
        case .adoptFocus:
            adoptFocusedWindow(of: pid)
        case .resync:
            scheduleReflow()
        case .ignore:
            break
        }
    }

    /// Light path for a click or app switch: no rescan. The frontmost app's
    /// focused window becomes the session focus (a background app changing
    /// its own key window is not the user's focus); an unknown window goes
    /// through single-window admission; a reflow follows only when the
    /// viewport has to scroll to show the focused column.
    private func adoptFocusedWindow(of pid: pid_t) {
        guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let element = focusedWindowElement(pid: pid)
        else {
            return
        }
        guard let id = actuator?.id(matching: element, pid: pid) else {
            // Registration focuses the new window and reflows.
            registerAppearedWindow(element, pid: pid, attempt: 0)
            return
        }
        if session.registry.find(id)?.isMinimized == true {
            return
        }
        adoptFocus(id)
        if viewportNeedsScroll() {
            reflowAll()
        }
    }

    /// A window appeared after startup (created or deminiaturized): classify
    /// it with the admission rules, register it, reflow at once. Attributes
    /// of a brand-new window are often unreadable for a moment, so an
    /// unclassifiable element is retried a few times. Minimized windows
    /// register too (out of the layout until deminimized).
    private func registerAppearedWindow(_ element: AXUIElement, pid: pid_t, attempt: Int) {
        if actuator?.id(matching: element, pid: pid) != nil {
            return
        }
        if let candidate = discoverSystemWindow(element: element, pid: pid) {
            registerNew(candidate)
            reflowAll()
        } else if let delay = WindowRegistrationRetry.delay(afterFailedAttempt: attempt) {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.registerAppearedWindow(element, pid: pid, attempt: attempt + 1)
            }
        }
    }

    /// Attach one launched app's observer, retrying with backoff while AX
    /// is not ready, then register its windows and reflow. Windows that
    /// appear later arrive through the app-level window-created event.
    private func attachLaunchedApp(_ pid: pid_t, attempt: Int) {
        guard let observer = eventObserver,
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular,
              observationBook.needsAttach(pid)
        else {
            return
        }
        if observer.attach(pid: pid) {
            observationBook.didAttach(pid)
            enumerateAndPlace(onlyPID: pid)
            reflowAll()
        } else if let delay = ObservationRetry.delay(afterFailedAttempt: attempt) {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.attachLaunchedApp(pid, attempt: attempt + 1)
            }
        } else {
            observationBook.didRefuse(pid)
            print("[gio] observation refused: pid \(pid)")
            GioLog.record(.warn, "observation refused for launched pid \(pid)")
        }
    }

    /// Terminate is proof of death: drop the observer, reap the windows,
    /// reflow now.
    private func handleTerminated(_ pid: pid_t) {
        eventObserver?.detach(pid: pid)
        observationBook.didDetach(pid)
        let ids = session.registry.managedWindows().map(\.id).filter { $0.pid == pid }
        purge(ids)
        reflowAll()
    }

    private func watchDisplays() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }
            self.queue.async {
                self.syncDisplays()
                self.reflowAll()
            }
        }
    }

    private func startTap() {
        let tap = HotkeyTap { [weak self] combo in
            self?.handleCombo(combo) ?? false
        }
        if tap.start() {
            hotkeyTap = tap
        } else {
            print("[gio] hotkey tap refused (grant Accessibility, then relaunch)")
            GioLog.record(.warn, "hotkey tap refused; running without global hotkeys")
        }
    }

    // MARK: - Actions (main thread in, session queue for work)

    private func handleCombo(_ combo: HotkeyCombo) -> Bool {
        if combo == HotkeyCombo(modifiers: [.alt], key: "Space") {
            DispatchQueue.main.async { [weak self] in
                self?.onSummonLauncher?()
            }
            return true
        }
        guard let action = dispatcher.action(for: combo) else {
            return false
        }
        queue.async { [weak self] in
            self?.apply(action)
        }
        return true
    }

    private func apply(_ action: HotkeyAction) {
        GioLog.record(.debug, "hotkey \(action)")
        var workspace = session.manager.currentWorkspace()
        switch action {
        case .focusLeft:
            let next = moveFocus(in: workspace, direction: .left)
            if next != workspace {
                workspace = next
                session.manager.update(workspace)
            }
        case .focusRight:
            let next = moveFocus(in: workspace, direction: .right)
            if next != workspace {
                workspace = next
                session.manager.update(workspace)
            }
        case .focusUp:
            let next = moveFocus(in: workspace, direction: .up)
            if next != workspace {
                workspace = next
                session.manager.update(workspace)
            }
        case .focusDown:
            let next = moveFocus(in: workspace, direction: .down)
            if next != workspace {
                workspace = next
                session.manager.update(workspace)
            }
        case .moveLeft:
            narrowMove(in: &workspace, direction: .left)
        case .moveRight:
            narrowMove(in: &workspace, direction: .right)
        case .moveUp:
            narrowMove(in: &workspace, direction: .up)
        case .moveDown:
            narrowMove(in: &workspace, direction: .down)
        case .workspace(let number):
            session.manager.switchTo(number)
        case .moveToWorkspace(let number):
            if let id = workspace.focusedWindow {
                session.manager.moveWindow(id, to: number)
            }
        case .toggleFloating:
            if let id = workspace.focusedWindow {
                _ = try? session.registry.toggleFloating(for: id)
            }
        case .fullscreen:
            toggleFullscreen()
        }
        reflowAll()
    }

    private func narrowMove(in workspace: inout Workspace, direction: FocusDirection) {
        let next = moveWindow(in: workspace, direction: direction)
        if next != workspace {
            workspace = next
            session.manager.update(workspace)
        }
    }

    private func toggleFullscreen() {
        let workspace = session.manager.currentWorkspace()
        guard let id = workspace.focusedWindow else {
            return
        }
        if let record = fullscreenRecords[id] {
            try? session.registry.endFullscreen(record)
            fullscreenRecords.removeValue(forKey: id)
            return
        }
        guard let display = displays.allDisplays().first else {
            return
        }
        if let record = try? session.registry.beginFullscreen(id: id, frame: display.frame) {
            fullscreenRecords[id] = record
        }
    }
}
