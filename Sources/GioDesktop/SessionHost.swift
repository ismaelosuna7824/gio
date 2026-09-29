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
    private var tileability = TileabilityCache()
    private var fullscreenRecords: [WindowID: FullscreenRecord] = [:]
    private var visibleFrames: [DisplayID: CGRect] = [:]
    private let dispatcher = HotkeyDispatcher()

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

    // MARK: - IPC

    private func handleIPC(_ argv: [String]) -> IPCResponse {
        let parsed = parseCLICommand(argv)
        let response = dispatchIPC(argv, session: &session)
        if case .success(let command) = parsed {
            switch command {
            case .focus, .move, .workspace, .reload:
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
        var focusedID: WindowID?
        let candidates = found.windows.filter { !$0.window.isMinimized }
            + found.floating.filter { !$0.window.isMinimized }
        for candidate in candidates {
            if let known = actuator?.id(
                matching: candidate.element, pid: candidate.window.pid
            ) {
                liveIDs.insert(known)
                if var record = session.registry.find(known) {
                    record.frame = flip.toCocoa(candidate.window.frame)
                    if let title = candidate.window.title, !title.isEmpty {
                        record.title = title
                    }
                    try? session.registry.update(record)
                }
                if candidate.window.isFocused {
                    focusedID = known
                }
                continue
            }
            nextElementID += 1
            let id = WindowID(pid: candidate.window.pid, elementID: nextElementID)
            liveIDs.insert(id)
            actuator?.register(
                elementID: id.elementID, pid: id.pid,
                element: candidate.element, appElement: candidate.appElement
            )
            var window = ManagedWindow(
                id: id, pid: candidate.window.pid,
                application: candidate.window.appName,
                title: candidate.window.title ?? "",
                frame: AXVerticalFlip(displayHeight: mainHeight()).toCocoa(candidate.window.frame),
                mode: .tiled
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
                dest.focusedColumn = dest.columns.count - 1
                dest.focusedWindow = id
                session.manager.update(dest)
            } else {
                var current = session.manager.currentWorkspace()
                var column = Column(
                    id: ColumnID((current.columns.map(\.id.rawValue).max() ?? 0) + 1),
                    width: 0, windows: [id]
                )
                column.focusedWindowIndex = 0
                current.columns.append(column)
                current.focusedColumn = current.columns.count - 1
                current.focusedWindow = id
                session.manager.update(current)
            }
        }
        // Clicks change macOS focus behind our back: adopt the observed
        // focus instead of fighting it on the next reflow.
        if let focusedID {
            var current = session.manager.currentWorkspace()
            if let row = current.columns.firstIndex(where: { $0.windows.contains(focusedID) }) {
                current.focusedColumn = row
                current.columns[row].focusedWindowIndex = current.columns[row].windows.firstIndex(of: focusedID)!
                current.focusedWindow = focusedID
                session.manager.update(current)
            }
        }
        if onlyPID == nil {
            reapDeadPids(live: liveIDs)
        }
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

    private func reflowAll() {
        guard let actuator else {
            return
        }
        let reconciler = WindowReconciler(actuator: actuator)
        let modes = tileableModes()
        for display in displays.allDisplays() {
            guard var workspace = session.manager.workspace(Int(display.workspace.rawValue)) else {
                continue
            }
            let visible = visibleFrames[display.id] ?? display.frame
            var layout: LayoutResult
            do {
                layout = try engine().calculate(
                    workspace: tilingWorkspace(from: workspace, modes: modes),
                    viewport: visible
                )
            } catch {
                continue
            }
            // Niri rule: the focused column is always visible. Reveal it
            // first, then lay out again from the scrolled offset so every
            // frame below is computed against the viewport users see.
            if let revealed = revealOffset(
                workspace: workspace, layout: layout, viewport: visible
            ), revealed != workspace.viewportOffset {
                var scrolled = workspace
                scrolled.viewportOffset = revealed
                if let relaid = try? engine().calculate(
                    workspace: tilingWorkspace(from: scrolled, modes: modes),
                    viewport: visible
                ) {
                    layout = relaid
                    workspace.viewportOffset = revealed
                }
            }
            let (placed, _) = splitVisibleFrames(layout.frames, in: visible)
            let focused = workspace.focusedWindow
            _ = reconciler.reconcile(
                frames: placed, focused: focused, currentlyFocused: focused
            )
            workspace.viewportOffset = layout.viewportOffset
            session.manager.update(workspace)
            displays.updateViewport(
                Viewport(offset: layout.viewportOffset, width: visible.width), for: display.id
            )
        }
    }

    /// Focused column's content range revealed into the viewport.
    /// Nil when nothing needs scrolling (or no focused window to reveal).
    private func revealOffset(
        workspace: Workspace, layout: LayoutResult, viewport: CGRect
    ) -> CGFloat? {
        guard let focused = workspace.focusedWindow,
              let column = workspace.columns.first(where: { $0.windows.contains(focused) })
        else {
            return nil
        }
        let frames = column.windows.compactMap { layout.frames[$0] }
        guard !frames.isEmpty else {
            return nil
        }
        let lower = frames.map(\.origin.x).min()!
        let upper = frames.map(\.maxX).max()!
        let revealed = Viewport(offset: workspace.viewportOffset, width: viewport.width)
            .ensureVisible(range: lower..<upper, contentWidth: layout.contentWidth)
        return revealed.offset == workspace.viewportOffset ? nil : revealed.offset
    }

    private func scheduleReflow() {
        pendingReflow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.resyncAndReflow()
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
        }
        // Events may mean a resize or attribute change: re-probe everyone.
        tileability.invalidateAll()
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
            scheduleReflow()
        case .accessibility:
            scheduleReflow()
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
