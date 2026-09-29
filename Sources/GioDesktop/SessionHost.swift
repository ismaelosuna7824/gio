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
    private var reconciler: WindowReconciler<AXWindowActuator>?
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
    private var fullscreen = FullscreenBook()
    private var visibleFrames: [DisplayID: CGRect] = [:]
    /// Effective hotkey table (defaults + config). Read on the main thread
    /// by the tap, rebuilt on the session queue at start and on reload.
    private let dispatcherLock = NSLock()
    private var dispatcherTable = HotkeyDispatcher()
    /// Config load messages (errors and warnings) for the Overview; on `queue`.
    private var configMessages: [String] = []
    private var isShuttingDown = false
    private var reflowDeferral = ReflowDeferral()
    /// MO-04: where each window physically is (last applied or sampled
    /// frame), the frame player and its display-rate timer. All on `queue`.
    private var physicalFrames: [WindowID: CGRect] = [:]
    private var player: MotionPlayer?
    private var motionTimer: DispatchSourceTimer?
    private var skipAnimationOnce = false
    /// NC-06: the workspace the last reflow showed (so a switch knows which
    /// display to repoint) and the pre-hide frames of floating windows.
    private var shownWorkspace: WorkspaceID?
    private var hiddenBook = HiddenWindowBook()
    private static let motionFrameInterval: DispatchTimeInterval = .microseconds(8333)
    private var focusSettle = FocusSettle<FocusEvent>()
    private let clickLock = NSLock()
    private var tappedClick: MouseClick?

    /// One focus signal awaiting adoption. `element` is the window the
    /// event itself carried (focused-window changes), if any.
    private struct FocusEvent: Equatable {
        let source: FocusSource
        let pid: pid_t
        let element: AXUIElement?

        static func == (lhs: FocusEvent, rhs: FocusEvent) -> Bool {
            lhs.source == rhs.source && lhs.pid == rhs.pid
                && sameElement(lhs.element, rhs.element)
        }
    }

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
        refreshDispatcher()
        self.configMessages = configMessages
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
            stopMotion()
            reconciler?.waitForMotionIdle(timeout: 0.3)
            restoreOffscreenWindows(session.registry.managedWindows().filter { !$0.isMinimized }.map(\.id))
        }
        server?.stop()
        instanceLock.release()
    }

    @discardableResult
    private func restoreOffscreenWindows(_ ids: [WindowID]) -> ReconcileReport? {
        guard let actuator, !ids.isEmpty else {
            return nil
        }
        return WindowReconciler(actuator: actuator)
            .restoreOffscreen(ids: ids, displays: restoreDisplays())
    }

    /// Diagnostics action: same restore the quit path runs, without
    /// quitting. Tiling stays active, so the next reflow re-parks
    /// off-viewport columns; this is a rescue, not a pause. Returns how
    /// many windows were moved.
    func restoreAllWindows() -> Int {
        queue.sync {
            pendingReflow?.cancel()
            stopMotion()
            reconciler?.waitForMotionIdle(timeout: 0.3)
            let ids = session.registry.managedWindows().filter { !$0.isMinimized }.map(\.id)
            let moved = restoreOffscreenWindows(ids)?.applied.count ?? 0
            GioLog.record(.info, "restore-all requested from the app moved=\(moved)")
            return moved
        }
    }

    /// Same effect as the IPC `reload` verb, driven by the app.
    func reloadConfig() {
        queue.sync {
            dispatch(.reload, session: &session)
            applyReloadedConfig()
            GioLog.record(.info, "config reloaded from the app")
        }
    }

    private func refreshDispatcher() {
        let table = session.config.makeDispatcher()
        dispatcherLock.lock()
        dispatcherTable = table
        dispatcherLock.unlock()
    }

    private func currentDispatcher() -> HotkeyDispatcher {
        dispatcherLock.lock()
        defer { dispatcherLock.unlock() }
        return dispatcherTable
    }

    /// Read-only state for the main window. Safe from any thread: it runs
    /// on the session queue.
    func snapshot() -> SessionSnapshot {
        queue.sync {
            SessionSnapshot(
                keybindings: session.config.keybindings, facts: sessionFacts(), config: session.config
            )
        }
    }

    /// Must run on `queue`.
    private func sessionFacts() -> SessionFacts {
        let displayStates = displays.allDisplays()
        let shown = displayStates.isEmpty
            ? [session.manager.current]
            : displayStates.map { Int($0.workspace.rawValue) }
        var owner: [WindowID: Int] = [:]
        for index in WorkspaceManager.range {
            for column in session.manager.workspace(index)?.columns ?? [] {
                for id in column.windows {
                    owner[id] = index
                }
            }
        }
        let windows = session.registry.managedWindows().map { window -> WindowFact in
            let workspace = owner[window.id]
            return WindowFact(
                id: "\(window.id.pid):\(window.id.elementID)",
                application: window.application, title: window.title, workspace: workspace,
                mode: window.mode, floatReason: window.floatReason,
                isMinimized: window.isMinimized,
                workspaceIsShown: workspace.map(shown.contains) ?? true
            )
        }
        let path = session.configPath
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/config.toml")
        return SessionFacts(
            configPath: path, configExists: FileManager.default.fileExists(atPath: path),
            configMessages: configMessages, accessibilityGranted: hasAXPermission(),
            currentWorkspace: session.manager.current,
            displays: displayStates.map {
                DisplayFact(id: $0.id.rawValue, workspace: Int($0.workspace.rawValue))
            },
            windows: windows
        )
    }

    /// Patch config.toml from the app, then reload it exactly like the IPC
    /// `reload` verb. Nothing is reloaded when the edit is rejected.
    func applyConfigEdits(_ edits: [ConfigEdit]) -> Result<PatchedConfig, ConfigErrors> {
        queue.sync {
            let result = GioCore.applyConfigEdits(edits)
            if case .success = result {
                dispatch(.reload, session: &session)
                applyReloadedConfig()
                GioLog.record(.info, "config edited from the app and reloaded")
            }
            return result
        }
    }

    /// After `session.config` changed: rebuild bindings and messages,
    /// re-evaluate rules, relayout. Must run on `queue`.
    private func applyReloadedConfig() {
        refreshDispatcher()
        configMessages = loadGioConfig().messages
        reapplyRules()
        reflowAll()
    }

    // MARK: - IPC

    private func handleIPC(_ argv: [String]) -> IPCResponse {
        let parsed = parseCLICommand(argv)
        let response = dispatchIPC(argv, session: &session)
        if case .success(let command) = parsed {
            switch command {
            case .reload:
                applyReloadedConfig()
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
        // A click in flight is the focus events' business (they validate
        // it against the click point), never the rescan's.
        if currentClick() == nil,
           let focusedID = adoptableFocus(
               among: focusCandidates,
               frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
           )
        {
            adoptFocus(focusedID, source: .rescan)
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
            physicalFrames.removeValue(forKey: id)
            fullscreen.forget(id)
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

    /// Adopt `id` as the session focus (current workspace), logging what it
    /// did to the viewport. True when the focus changed. Callers that adopt
    /// outside a reflow follow up with `reflowAll` when `scrolls` is set.
    @discardableResult
    private func adoptFocus(_ id: WindowID, source: FocusSource) -> Bool {
        let current = session.manager.currentWorkspace()
        let column = current.columns.firstIndex { $0.windows.contains(id) }
        let visibility = isVisibleInViewport(id)
        guard let adopted = adoptingFocus(id, in: current), adopted != current else {
            logAdoption(source, id, column, visibility, changed: false)
            return false
        }
        session.manager.update(adopted)
        logAdoption(source, id, column, visibility, changed: true)
        return true
    }

    private func logAdoption(
        _ source: FocusSource, _ id: WindowID, _ column: Int?, _ visible: Bool?, changed: Bool
    ) {
        let scroll = pendingScroll().map { "\(Int($0.from))->\(Int($0.to))" } ?? "no scroll"
        let placement = visible.map { $0 ? "visible" : "parked" } ?? "unplaced"
        GioLog.record(
            .debug,
            "focus adopt source=\(source.rawValue) id=\(id.pid):\(id.elementID) "
                + "column=\(column.map(String.init) ?? "none") \(placement) "
                + "changed=\(changed) scroll=\(scroll)"
        )
    }

    /// Would `id` be inside its display's viewport under the current offset?
    private func isVisibleInViewport(_ id: WindowID) -> Bool? {
        let modes = tileableModes()
        for display in displays.allDisplays() {
            guard let workspace = session.manager.workspace(Int(display.workspace.rawValue)),
                  workspace.columns.contains(where: { $0.windows.contains(id) })
            else {
                continue
            }
            let viewport = visibleFrames[display.id] ?? display.frame
            guard let layout = try? engine().calculate(
                workspace: tilingWorkspace(from: workspace, modes: modes), viewport: viewport
            ), let frame = layout.frames[id]
            else {
                return nil
            }
            return frame.intersects(viewport)
        }
        return nil
    }

    /// The viewport move laying out the current workspaces would make
    /// (focused column hidden, or offset out of bounds), if any. Decides
    /// whether a click on an already-visible column needs any reflow.
    private func pendingScroll() -> (from: CGFloat, to: CGFloat)? {
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
                return (workspace.viewportOffset, planned.workspace.viewportOffset)
            }
        }
        return nil
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

    private func performReflow(animate: Bool = true) {
        guard let actuator else {
            return
        }
        // One reconciler for the session: it remembers apps whose write lane
        // is still stuck so a hung app is never written twice at once.
        let reconciler = self.reconciler ?? WindowReconciler(
            actuator: actuator,
            appName: { NSRunningApplication(processIdentifier: $0)?.localizedName }
        )
        self.reconciler = reconciler
        let settings = session.config.animations
        let skip = skipAnimationOnce
        skipAnimationOnce = false
        let animating = animate && !skip && settings.isActive
        // Focusing away from a fullscreen window brings its column back.
        fullscreen.release(
            keeping: Set(displays.allDisplays().compactMap {
                session.manager.workspace(Int($0.workspace.rawValue))?.focusedWindow
            }),
            registry: session.registry
        )
        syncShownWorkspace()
        let modes = tileableModes()
        var plans: [ParkingPlan] = []
        var animations: [WindowAnimation] = []
        var prepositions: [WindowID: CGRect] = [:]
        let inactive = planInactiveWorkspaces()
        for (index, display) in displays.allDisplays().enumerated() {
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
            plans.append(planned.plan)
            if animating {
                // NC-07: the first display also carries the workspace switch:
                // hidden windows drop below its bottom edge, revealed ones rise.
                let carriesSwitch = index == 0
                let motionFrames = carriesSwitch
                    ? planned.plan.visible.merging(inactive.visible) { first, _ in first }
                    : planned.plan.visible
                learnPhysicalFrames(of: motionFrames.keys)
                let motion = planWorkspaceSwitchMotion(
                    current: physicalFrames, visible: motionFrames,
                    parked: planned.plan.parked, hidden: carriesSwitch ? inactive.parked : [:],
                    viewport: visible, display: display.frame, duration: settings.duration
                )
                animations += motion.animations
                prepositions.merge(motion.prepositions) { _, new in new }
            }
            // Logical state moves at once; only the physical writes animate.
            session.manager.update(planned.workspace)
            displays.updateViewport(
                Viewport(offset: planned.layout.viewportOffset, width: visible.width), for: display.id
            )
        }
        plans.append(inactive)
        if !animations.isEmpty {
            applyPrepositions(prepositions)
            startMotion(animations, reconciler: reconciler)
            return
        }
        stopMotion()
        for plan in plans {
            // Never let the reconciler raise a minimized window: reflow
            // applies geometry only, focus is adopted elsewhere.
            let report = reconciler.reconcile(
                frames: plan.visible, parked: plan.parked, focused: nil, currentlyFocused: nil
            )
            GioLog.record(
                .info,
                "reflow applied=\(report.applied.count) parked=\(report.parked.count) already=\(report.alreadyCorrect.count) failed=\(report.failed.count)"
            )
            // Our writes echo back as moved/resized events: remember them
            // (parked ones too, so they never retrigger a reflow).
            let applied = plan.visible.merging(plan.parked.mapValues(\.frame)) { first, _ in first }
            echoGate.recordApplied(applied, at: ProcessInfo.processInfo.systemUptime)
            physicalFrames.merge(applied) { _, new in new }
            for id in report.failed + report.vanished {
                physicalFrames.removeValue(forKey: id)
            }
        }
    }

    // MARK: - Workspace visibility (NC-06)

    /// Point a display at the current workspace when none shows it yet: the
    /// display that showed the previous one switches over.
    private func syncShownWorkspace() {
        let current = WorkspaceID(UInt64(session.manager.current))
        displays.show(current, replacing: shownWorkspace)
        shownWorkspace = current
    }

    /// Windows of workspaces no display shows hang off a corner of the first
    /// display (size kept); floating windows of shown workspaces that were
    /// hidden return to the frame they had. Minimized windows are untouched.
    private func planInactiveWorkspaces() -> ParkingPlan {
        let all = displays.allDisplays()
        var plan = ParkingPlan(visible: [:], parked: [:])
        guard let hiddenDisplay = all.first else {
            return plan
        }
        let shown = Set(all.map { Int($0.workspace.rawValue) })
        let windows = Dictionary(
            uniqueKeysWithValues: session.registry.managedWindows().map { ($0.id, $0) }
        )
        let hidden = session.manager.windows(outside: shown).filter {
            windows[$0].map { !$0.isMinimized } ?? false
        }
        learnPhysicalFrames(of: hidden)
        var frames: [WindowID: CGRect] = [:]
        for id in hidden {
            guard let frame = physicalFrames[id] else {
                continue
            }
            frames[id] = frame
            if windows[id]?.mode == .floating {
                hiddenBook.hide(id, from: frame)
            }
        }
        plan.parked = planHiddenWindows(
            frames: frames, display: hiddenDisplay.frame,
            otherDisplays: all.filter { $0.id != hiddenDisplay.id }.map(\.frame)
        )
        let active = shown.flatMap { index in
            (session.manager.workspace(index)?.columns ?? []).flatMap(\.windows)
        }
        // Keep the memory until the window really sits at its frame: a
        // retarget mid-flight (or an abandoned animation) must find it again.
        let floating = active.filter { windows[$0]?.mode == .floating }
        plan.visible = hiddenBook.frames(of: floating)
        for (id, frame) in plan.visible {
            if let physical = physicalFrames[id],
               abs(physical.minX - frame.minX) <= 1, abs(physical.minY - frame.minY) <= 1
            {
                _ = hiddenBook.reveal([id])
            }
        }
        return plan
    }

    // MARK: - Motion (MO-04)

    /// Windows about to be seen but never placed by us (new ones) have no
    /// known physical frame; one read each lets them slide in.
    private func learnPhysicalFrames(of ids: some Sequence<WindowID>) {
        for id in ids where physicalFrames[id] == nil {
            if let frame = try? actuator?.frame(of: id) {
                physicalFrames[id] = frame
            }
        }
    }

    /// Place hidden incoming windows directly below their target before the
    /// player starts (off-screen, so the jump is invisible).
    private func applyPrepositions(_ frames: [WindowID: CGRect]) {
        for id in frames.keys.sorted() {
            guard let frame = frames[id], let from = physicalFrames[id] else {
                continue
            }
            try? actuator?.setFrame(frame, from: from, for: id, verify: false)
            physicalFrames[id] = frame
            echoGate.recordApplied([id: frame], at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func startMotion(_ animations: [WindowAnimation], reconciler: WindowReconciler<AXWindowActuator>) {
        let player = self.player ?? MotionPlayer(
            sink: reconciler,
            appName: { NSRunningApplication(processIdentifier: $0)?.localizedName }
        )
        self.player = player
        player.start(animations)
        guard motionTimer == nil else {
            return
        }
        // A display-rate timer on the session queue: a tick only samples and
        // hands frames to per-app lanes (never an AX call here), so it costs
        // microseconds, and sampling by elapsed time keeps late ticks honest.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.motionFrameInterval, leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            self?.motionTick()
        }
        motionTimer = timer
        timer.resume()
    }

    private func stopMotion() {
        motionTimer?.cancel()
        motionTimer = nil
        player?.cancel()
    }

    private func motionTick() {
        guard let player, player.isActive, !isShuttingDown else {
            stopMotion()
            return
        }
        if NSEvent.pressedMouseButtons != 0 {
            // Nothing moves under the cursor: abandon the flight, and let
            // the deferred reflow finish instantly after release.
            stopMotion()
            skipAnimationOnce = true
            reflowAll()
            return
        }
        let tick = player.tick()
        physicalFrames.merge(tick.sampled) { _, new in new }
        // Frame writes raise moved events like any other write of ours.
        echoGate.recordApplied(tick.sampled, at: ProcessInfo.processInfo.systemUptime)
        if let summary = tick.summary {
            stopMotion()
            GioLog.record(.info, summary.logLine)
            performReflow(animate: false)
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
            requestFocusAdoption(.activation, pid: event.pid, element: nil)
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
            // Animation frames raise a burst of events: skip the AX read.
            if echoGate.isSuppressed(known, at: ProcessInfo.processInfo.systemUptime) {
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
            requestFocusAdoption(.focusChanged, pid: pid, element: element)
        case .resync:
            scheduleReflow()
        case .ignore:
            break
        }
    }

    /// The click explaining a focus event right now, if any: a button is
    /// down or one went down moments ago, at a point inside a window area.
    private func currentClick() -> MouseClick? {
        clickLock.lock()
        let tapped = tappedClick
        clickLock.unlock()
        let click = recentClick(
            pressed: NSEvent.pressedMouseButtons != 0,
            currentLocation: NSEvent.mouseLocation,
            now: ProcessInfo.processInfo.systemUptime,
            lastTapped: tapped
        )
        return windowAreaClick(
            click, visibleAreas: displays.allDisplays().map { visibleFrames[$0.id] ?? $0.frame }
        )
    }

    /// Light path for a click or app switch: no rescan. Keyboard-driven
    /// events adopt at once; mouse-driven ones coalesce, settle and are
    /// validated against the click (`FocusSettle`). The activation and the
    /// focused-window event of one click therefore adopt once.
    private func requestFocusAdoption(_ source: FocusSource, pid: pid_t, element: AXUIElement?) {
        // Gio's own window (main window, launcher) is never a tiling focus.
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        // A background app changing its own key window is not the user's focus.
        if source == .focusChanged,
           pid != NSWorkspace.shared.frontmostApplication?.processIdentifier
        {
            return
        }
        let event = FocusEvent(source: source, pid: pid, element: element)
        switch focusSettle.request(event, click: currentClick()) {
        case .adoptNow(let event):
            if let element = focusedElement(for: event, fresh: false) {
                adoptResolved(element, event: event)
            }
        case .wait(let delay):
            scheduleFocusPoll(after: delay)
        case .coalesced:
            break
        }
    }

    private func scheduleFocusPoll(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isShuttingDown else {
                return
            }
            let poll = self.focusSettle.poll(
                mouseDown: NSEvent.pressedMouseButtons != 0,
                now: ProcessInfo.processInfo.systemUptime
            )
            switch poll {
            case .idle:
                break
            case .wait(let next):
                self.scheduleFocusPoll(after: next)
            case .resolve(let event, let click):
                self.validateClickFocus(event, click: click, fresh: false)
            }
        }
    }

    /// The window to adopt: the one the event carried the first time, the
    /// app's current key window when re-reading.
    private func focusedElement(for event: FocusEvent, fresh: Bool) -> AXUIElement? {
        if !fresh, let element = event.element {
            return element
        }
        return focusedWindowElement(pid: event.pid)
    }

    private func validateClickFocus(_ event: FocusEvent, click: MouseClick, fresh: Bool) {
        let element = NSWorkspace.shared.frontmostApplication?.processIdentifier == event.pid
            ? focusedElement(for: event, fresh: fresh) : nil
        let known = element.flatMap { actuator?.id(matching: $0, pid: event.pid) }
        var matches = false
        var frame: CGRect?
        if let known {
            frame = try? actuator?.frame(of: known)
            matches = focusMatchesClick(frame: frame, click: click.location)
        } else if element != nil {
            // Unknown window: single-window admission decides, nothing to compare.
            matches = true
        }
        switch focusSettle.judge(matchesClick: matches) {
        case .adopt:
            if let element {
                adoptResolved(element, event: event)
            }
        case .retry(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isShuttingDown,
                      let (latest, latestClick) = self.focusSettle.resolveAgain()
                else {
                    return
                }
                self.validateClickFocus(latest, click: latestClick, fresh: true)
            }
        case .giveUp:
            let id = known.map { "\($0.pid):\($0.elementID)" } ?? "none"
            let box = frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }
                ?? "unreadable"
            GioLog.record(
                .debug,
                "focus dropped source=\(event.source.rawValue) id=\(id) frame=\(box) "
                    + "click=\(Int(click.location.x)),\(Int(click.location.y)) "
                    + "reason=focused window not under click"
            )
        }
    }

    /// The frontmost app's window becomes the session focus; an unknown
    /// window goes through single-window admission; a reflow follows only
    /// when the viewport has to scroll to show the focused column.
    private func adoptResolved(_ element: AXUIElement, event: FocusEvent) {
        guard event.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return
        }
        guard let id = actuator?.id(matching: element, pid: event.pid) else {
            // Registration focuses the new window and reflows.
            registerAppearedWindow(element, pid: event.pid, attempt: 0)
            return
        }
        if session.registry.find(id)?.isMinimized == true {
            return
        }
        adoptFocus(id, source: event.source)
        if pendingScroll() != nil {
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

    private func recordClick(at location: CGPoint) {
        clickLock.lock()
        tappedClick = MouseClick(location: location, time: ProcessInfo.processInfo.systemUptime)
        clickLock.unlock()
    }

    private func startTap() {
        let tap = HotkeyTap(
            onMouseDown: { [weak self] location in
                self?.recordClick(at: location)
            },
            onCombo: { [weak self] combo in
                self?.handleCombo(combo) ?? false
            }
        )
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
        guard let action = currentDispatcher().action(for: combo) else {
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
            syncShownWorkspace()
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
        case .switchPresetColumnWidth:
            let sizing = focusedSizing()
            let next = switchPresetColumnWidth(
                in: workspace, presets: session.config.layout.presetColumnWidths,
                config: sizing.config, viewportWidth: sizing.viewportWidth
            )
            commit(next, over: workspace)
        case .shrinkColumnWidth, .growColumnWidth:
            let sizing = focusedSizing()
            let next = stepFocusedColumnWidth(
                in: workspace, by: action == .growColumnWidth ? 0.1 : -0.1,
                config: sizing.config, viewportWidth: sizing.viewportWidth
            )
            commit(next, over: workspace)
        case .maximizeColumn:
            commit(toggleMaximizeFocusedColumn(in: workspace), over: workspace)
        case .consumeOrExpelLeft:
            commit(consumeOrExpelWindow(in: workspace, direction: .left), over: workspace)
        case .consumeOrExpelRight:
            commit(consumeOrExpelWindow(in: workspace, direction: .right), over: workspace)
        case .centerColumn:
            let viewport = focusedViewport()
            commit(
                centerFocusedColumn(in: workspace, modes: tileableModes(), engine: engine(), viewport: viewport),
                over: workspace
            )
        }
        reflowAll()
    }

    /// Store `next` when an action changed anything.
    private func commit(_ next: Workspace, over current: Workspace) {
        if next != current {
            session.manager.update(next)
        }
    }

    /// Usable frame of the display showing the current workspace.
    private func focusedViewport() -> CGRect {
        let current = session.manager.current
        let display = displays.allDisplays().first { Int($0.workspace.rawValue) == current }
            ?? displays.allDisplays().first
        return display.map { visibleFrames[$0.id] ?? $0.frame }
            ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1800, height: 1000)
    }

    /// Layout config plus the viewport width of the display showing the
    /// current workspace: what width actions resolve proportions against.
    private func focusedSizing() -> (config: LayoutConfig, viewportWidth: CGFloat) {
        (engine().config, focusedViewport().width)
    }

    private func narrowMove(in workspace: inout Workspace, direction: FocusDirection) {
        let next = moveWindow(in: workspace, direction: direction)
        if next != workspace {
            workspace = next
            session.manager.update(workspace)
        }
    }

    /// Fullscreen is a layout mode: flip it in the registry and let the
    /// reflow place the window (see `planDisplayLayout`). Never native Spaces.
    private func toggleFullscreen() {
        let workspace = session.manager.currentWorkspace()
        guard let id = workspace.focusedWindow else {
            return
        }
        let current = session.manager.current
        guard let display = displays.allDisplays().first(where: { Int($0.workspace.rawValue) == current })
            ?? displays.allDisplays().first
        else {
            return
        }
        let frame = fullscreenFrame(display: display.frame, usable: visibleFrames[display.id] ?? display.frame)
        try? fullscreen.toggle(id, registry: session.registry, frame: frame)
    }
}

/// Same AX element (CFEqual), or both absent.
private func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (let lhs?, let rhs?): return CFEqual(lhs, rhs)
    default: return false
    }
}
