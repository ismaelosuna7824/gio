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
        public var configMessages: () -> [String]
        public var engine: () -> ScrollableLayoutEngine
        public var tileableModes: () -> [WindowID: WindowMode]
        public var screenRecordingGranted: () -> Bool
        public var accessibilityGranted: () -> Bool
        public var configFileExists: (String) -> Bool
        public var homeDirectory: () -> String
        /// SM-02b: refresh the shareable content when the snapshot renderer is in force.
        public var prefetchSnapshotContent: (Bool) -> Void
        /// PF-L: the WindowServer transport's state (config, symbols, probe).
        public var windowServerStatus: () -> WindowServerTransportStatus
        public var log: (LogLevel, String) -> Void

        public init(
            session: @escaping () -> CommandSession, displays: @escaping () -> [DisplayState],
            visibleFrame: @escaping (DisplayID) -> CGRect?, configMessages: @escaping () -> [String],
            engine: @escaping () -> ScrollableLayoutEngine, tileableModes: @escaping () -> [WindowID: WindowMode],
            screenRecordingGranted: @escaping () -> Bool, accessibilityGranted: @escaping () -> Bool,
            configFileExists: @escaping (String) -> Bool, homeDirectory: @escaping () -> String,
            prefetchSnapshotContent: @escaping (Bool) -> Void,
            windowServerStatus: @escaping () -> WindowServerTransportStatus,
            log: @escaping (LogLevel, String) -> Void
        ) {
            self.windowServerStatus = windowServerStatus
            self.session = session
            self.displays = displays
            self.visibleFrame = visibleFrame
            self.configMessages = configMessages
            self.engine = engine
            self.tileableModes = tileableModes
            self.screenRecordingGranted = screenRecordingGranted
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
    /// PF-L: logs `skylight available=... reason=...` once, then on change.
    private var windowServerLog = WindowServerStatusLogGate()

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
        let screenRecording = context.screenRecordingGranted()
        if let line = rendererLog.line(config: session.config.animations, permission: screenRecording) {
            context.log(.info, line)
        }
        context.prefetchSnapshotContent(
            effectiveRenderer(config: session.config.animations, permission: screenRecording) == .snapshot
        )
        let windowServer = context.windowServerStatus()
        if let line = windowServerLog.line(for: windowServer) {
            context.log(.info, line)
        }
        return SessionFacts(
            configPath: path, configExists: context.configFileExists(path),
            configMessages: context.configMessages(), accessibilityGranted: context.accessibilityGranted(),
            currentWorkspace: session.manager.current,
            displays: displayStates.map {
                DisplayFact(
                    id: $0.id.rawValue,
                    workspace: summaries[$0.id]?.activeIndex ?? 1,
                    stack: summaries[$0.id]?.workspaces ?? []
                )
            },
            windows: windows, screenRecordingGranted: screenRecording,
            strip: workspaceStrip(), windowServer: windowServer
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
    /// out against the display's usable frame.
    private func strip(
        _ workspace: Workspace, index: Int, on display: DisplayState, session: CommandSession
    ) -> WorkspaceStripFact? {
        let viewport = context.visibleFrame(display.id) ?? display.frame
        let tiling = tilingWorkspace(from: workspace, modes: context.tileableModes())
        guard let layout = try? context.engine().calculate(workspace: tiling, viewport: viewport) else {
            return nil
        }
        return makeWorkspaceStrip(
            workspace: tiling, layout: layout, viewport: viewport, displayID: display.id.rawValue,
            index: index,
            application: { session.registry.find($0)?.application ?? "" }
        )
    }
}
