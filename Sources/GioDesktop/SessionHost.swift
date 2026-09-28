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
    private var lastPIDs: Set<pid_t> = []
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
        refreshEventObservation()
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
    private func enumerateAndPlace() {
        guard let found = try? discoverSystemWindows() else {
            return
        }
        let flip = AXVerticalFlip(displayHeight: mainHeight())
        var liveIDs = Set<WindowID>()
        var focusedID: WindowID?
        for candidate in found.windows where !candidate.window.isMinimized {
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
        reapDeadPids(live: liveIDs)
        lastPIDs = Set(found.windows.map(\.window.pid))
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
        let deadSet = Set(dead)
        for id in dead.sorted() {
            session.registry.remove(id)
            fullscreenRecords.removeValue(forKey: id)
        }
        for index in WorkspaceManager.range {
            guard var workspace = session.manager.workspace(index) else {
                continue
            }
            let before = workspace
            workspace.stripWindows(deadSet)
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
        var modes: [WindowID: WindowMode] = [:]
        for window in session.registry.managedWindows() {
            guard window.mode == .tiled,
                  let element = actuator?.element(for: window.id),
                  axIsTileable(element)
            else {
                continue
            }
            modes[window.id] = .tiled
        }
        return modes
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

    func scheduleReflow() {
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
        enumerateAndPlace()
        if Set(lastPIDs) != Set(snapshotPIDs()) {
            refreshEventObservation()
        }
        reflowAll()
    }

    private func snapshotPIDs() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
    }

    // MARK: - Observers

    private func refreshEventObservation() {
        eventObserver?.stop()
        eventObserver = SystemWindowObserver { [weak self] _ in
            self?.scheduleReflow()
        }
        if let refused = eventObserver?.refused, !refused.isEmpty {
            print("[gio] observation refused: \(refused.joined(separator: ", "))")
            GioLog.record(.warn, "observation refused for \(refused.count) app(s)")
        }
        lastPIDs = snapshotPIDs()
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
