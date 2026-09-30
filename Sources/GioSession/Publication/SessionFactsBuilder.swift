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
        public var log: (LogLevel, String) -> Void

        public init(
            session: @escaping () -> CommandSession, displays: @escaping () -> [DisplayState],
            visibleFrame: @escaping (DisplayID) -> CGRect?, configMessages: @escaping () -> [String],
            engine: @escaping () -> ScrollableLayoutEngine, tileableModes: @escaping () -> [WindowID: WindowMode],
            screenRecordingGranted: @escaping () -> Bool, accessibilityGranted: @escaping () -> Bool,
            configFileExists: @escaping (String) -> Bool, homeDirectory: @escaping () -> String,
            prefetchSnapshotContent: @escaping (Bool) -> Void, log: @escaping (LogLevel, String) -> Void
        ) {
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
            strip: workspaceStrip()
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
        let viewport = context.visibleFrame(display.id) ?? display.frame
        let workspace = tilingWorkspace(from: session.manager.currentWorkspace(), modes: context.tileableModes())
        guard let layout = try? context.engine().calculate(workspace: workspace, viewport: viewport) else {
            return nil
        }
        return makeWorkspaceStrip(
            workspace: workspace, layout: layout, viewport: viewport, displayID: display.id.rawValue,
            index: session.manager.current,
            application: { session.registry.find($0)?.application ?? "" }
        )
    }
}
