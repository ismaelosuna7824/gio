import CoreGraphics
import GioCore

/// The Overview's read-only facts about the session (windows, displays,
/// permissions, config) and the DD-02 workspace strip. Pure session
/// bookkeeping plus the injected permission and file checks; no AX.
/// Session queue only. Logs never carry window titles.
public final class SessionFactsBuilder: @unchecked Sendable {
    public struct Context {
        public var session: () -> CommandSession
        public var displays: () -> [DisplayState]
        public var visibleFrame: (DisplayID) -> CGRect?
        /// The config file's load outcome: messages and whether it was rejected.
        public var configStatus: () -> ConfigLoadStatus
        public var engine: () -> ScrollableLayoutEngine
        public var tileableModes: () -> [WindowID: WindowMode]
        /// PA-15b: the cached permission (TTL), read on every publication.
        public var screenRecordingGranted: () -> Bool
        /// The uncached check (~8 ms tccd IPC), only while the cached
        /// answer is missing, so a fresh grant shows at once.
        public var refreshScreenRecording: () -> Bool
        public var accessibilityGranted: () -> Bool
        public var configFileExists: (String) -> Bool
        public var homeDirectory: () -> String
        /// SM-02b: refresh the shareable content when the snapshot renderer is in force.
        public var prefetchSnapshotContent: (Bool) -> Void
        /// TG-03: whether trackpad gestures run (symbols, config, devices).
        public var gestureStatus: () -> GestureSourceStatus
        /// TG-04: Gio's gestures macOS performs too (from its preferences).
        public var gestureConflicts: () -> [GestureConflict]
        public var log: (LogLevel, String) -> Void

        public init(
            session: @escaping () -> CommandSession, displays: @escaping () -> [DisplayState],
            visibleFrame: @escaping (DisplayID) -> CGRect?, configStatus: @escaping () -> ConfigLoadStatus,
            engine: @escaping () -> ScrollableLayoutEngine, tileableModes: @escaping () -> [WindowID: WindowMode],
            screenRecordingGranted: @escaping () -> Bool, refreshScreenRecording: @escaping () -> Bool,
            accessibilityGranted: @escaping () -> Bool,
            configFileExists: @escaping (String) -> Bool, homeDirectory: @escaping () -> String,
            prefetchSnapshotContent: @escaping (Bool) -> Void,
            gestureStatus: @escaping () -> GestureSourceStatus,
            gestureConflicts: @escaping () -> [GestureConflict],
            log: @escaping (LogLevel, String) -> Void
        ) {
            self.gestureStatus = gestureStatus
            self.gestureConflicts = gestureConflicts
            self.session = session
            self.displays = displays
            self.visibleFrame = visibleFrame
            self.configStatus = configStatus
            self.engine = engine
            self.tileableModes = tileableModes
            self.screenRecordingGranted = screenRecordingGranted
            self.refreshScreenRecording = refreshScreenRecording
            self.accessibilityGranted = accessibilityGranted
            self.configFileExists = configFileExists
            self.homeDirectory = homeDirectory
            self.prefetchSnapshotContent = prefetchSnapshotContent
            self.log = log
        }
    }

    private let context: Context
    /// SM-01: logs the effective renderer only when it changes.
    private var rendererLog = RendererLogGate()
    /// TG-03: logs `gestures available=... reason=...` once, then on change.
    private var gestureLog = GestureStatusLogGate()
    /// TG-04: logs `gestures conflict=...` once, then on change.
    private var conflictLog = GestureConflictLogGate()

    public init(context: Context) {
        self.context = context
    }

    public func facts() -> SessionFacts {
        let session = context.session()
        let displayStates = context.displays()
        let shown = session.manager.activeIDs
        var owner: [WindowID: (index: Int, id: WorkspaceID)] = [:]
        for display in session.manager.displayIDs {
            for (offset, workspace) in session.manager.stack(on: display).enumerated() {
                for column in workspace.columns {
                    for id in column.windows {
                        owner[id] = (offset + 1, workspace.id)
                    }
                }
            }
        }
        let summaries = Dictionary(
            uniqueKeysWithValues: session.manager.stackSummaries().map { ($0.display, $0) }
        )
        let windows = session.registry.managedWindows().map { window -> WindowFact in
            let workspace = owner[window.id]?.index
            return WindowFact(
                id: "\(window.id.pid):\(window.id.elementID)",
                application: window.application, title: window.title, workspace: workspace,
                mode: window.mode, floatReason: window.floatReason,
                isMinimized: window.isMinimized,
                workspaceIsShown: owner[window.id].map { shown.contains($0.id) } ?? true
            )
        }
        let path = session.configPath ?? (context.homeDirectory() + "/.config/gio/config.toml")
        let screenRecording = context.screenRecordingGranted() || context.refreshScreenRecording()
        if let line = rendererLog.line(config: session.config.animations, permission: screenRecording) {
            context.log(.info, line)
        }
        context.prefetchSnapshotContent(
            effectiveRenderer(config: session.config.animations, permission: screenRecording) == .snapshot
        )
        let gestures = context.gestureStatus()
        if let line = gestureLog.line(for: gestures) {
            context.log(.info, line)
        }
        let conflicts = context.gestureConflicts()
        if let line = conflictLog.line(for: conflicts) {
            context.log(conflicts.isEmpty ? .info : .warn, line)
        }
        let configStatus = context.configStatus()
        return SessionFacts(
            configPath: path, configExists: context.configFileExists(path),
            configMessages: configStatus.messages, configRejected: configStatus.rejected,
            accessibilityGranted: context.accessibilityGranted(),
            currentWorkspace: session.manager.current,
            displays: displayStates.map {
                DisplayFact(
                    id: $0.id.rawValue,
                    workspace: summaries[$0.id]?.activeIndex ?? 1,
                    stack: summaries[$0.id]?.workspaces ?? []
                )
            },
            windows: windows, screenRecordingGranted: screenRecording,
            strip: workspaceStrip(), gestures: gestures, gestureConflicts: conflicts
        )
    }

    /// DD-02: the focused display's current workspace laid out as a strip
    /// for the Overview miniature. Pure layout math on session state.
    public func workspaceStrip() -> WorkspaceStripFact? {
        let session = context.session()
        let focused = session.manager.focusedDisplay
        guard let display = context.displays().first(where: { $0.id == focused }) else {
            return nil
        }
        return strip(session.manager.currentWorkspace(), index: session.manager.current, on: display, session: session)
    }

    /// WO-01: every workspace of the focused display's stack as a strip, in
    /// stack order, for the workspace overview. Built on demand (not on
    /// every publication): one layout pass per workspace.
    public func workspaceOverview() -> WorkspaceOverviewFacts? {
        let session = context.session()
        let focused = session.manager.focusedDisplay
        guard let display = context.displays().first(where: { $0.id == focused }) else {
            return nil
        }
        let stack = session.manager.stack(on: focused)
        let active = session.manager.activeID(on: focused)
        let strips = stack.enumerated().compactMap { offset, workspace in
            strip(workspace, index: offset + 1, on: display, session: session)
        }
        return WorkspaceOverviewFacts(
            displayID: display.id.rawValue,
            activeWorkspace: (stack.firstIndex { $0.id == active } ?? 0) + 1,
            strips: strips
        )
    }

    /// Pure layout math on session state: the workspace's tiled windows laid
    /// out against the display's usable frame (DW-04: dwindle tiles for a
    /// dwindle workspace).
    private func strip(
        _ workspace: Workspace, index: Int, on display: DisplayState, session: CommandSession
    ) -> WorkspaceStripFact? {
        let viewport = context.visibleFrame(display.id) ?? display.frame
        let modes = context.tileableModes()
        let tiling = tilingWorkspace(from: workspace, modes: modes)
        guard let layout = try? workspaceLayoutResult(workspace, modes: modes, engine: context.engine(), viewport: viewport)
        else {
            return nil
        }
        return makeWorkspaceStrip(
            workspace: tiling, layout: layout, viewport: viewport, displayID: display.id.rawValue,
            index: index,
            application: { session.registry.find($0)?.application ?? "" }
        )
    }
}
