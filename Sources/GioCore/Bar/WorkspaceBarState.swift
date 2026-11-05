import Foundation

/// SB-01: one workspace as a custom bar (SketchyBar) shows it. `display` is
/// the display number `[[workspace]] display` uses (1 is the main display),
/// `index` the position in that display's stack. `windows` counts every
/// window the workspace holds (tiled, floating, fullscreen and minimized);
/// `apps` are their app names, unique, in column order. No window titles.
public struct WorkspaceBarEntry: Equatable, Sendable, Encodable {
    public let display: Int
    public let index: Int
    /// Nil for a dynamic workspace.
    public let name: String?
    public let icon: String?
    public let color: String?
    public let windows: Int
    public let apps: [String]
    /// The focused display's active workspace.
    public let focused: Bool
    /// Active on its display.
    public let visible: Bool

    public init(
        display: Int, index: Int, name: String? = nil, icon: String? = nil, color: String? = nil,
        windows: Int, apps: [String], focused: Bool, visible: Bool
    ) {
        self.display = display
        self.index = index
        self.name = name
        self.icon = icon
        self.color = color
        self.windows = windows
        self.apps = apps
        self.focused = focused
        self.visible = visible
    }

    private enum CodingKeys: String, CodingKey {
        case display, index, name, icon, color, windows, apps, focused, visible
    }

    /// Written out so a missing name, icon or color is `null`, not absent.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(display, forKey: .display)
        try container.encode(index, forKey: .index)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(color, forKey: .color)
        try container.encode(windows, forKey: .windows)
        try container.encode(apps, forKey: .apps)
        try container.encode(focused, forKey: .focused)
        try container.encode(visible, forKey: .visible)
    }
}

/// SB-01: the snapshot the hooks diff and `gio list-workspaces --json`
/// prints: the focused display and workspace, then every display's stack
/// (display number order, top to bottom).
public struct WorkspaceBarState: Equatable, Sendable {
    public let focusedDisplay: Int
    public let focusedWorkspace: Int
    public let focusedName: String?
    public let workspaces: [WorkspaceBarEntry]

    public init(focusedDisplay: Int, focusedWorkspace: Int, focusedName: String?, workspaces: [WorkspaceBarEntry]) {
        self.focusedDisplay = focusedDisplay
        self.focusedWorkspace = focusedWorkspace
        self.focusedName = focusedName
        self.workspaces = workspaces
    }
}

extension WorkspaceManager {
    /// The number `display(numbered:)` resolves to `display`: 1 is the main
    /// display, the others follow in position order. Nil when not connected.
    public func displayNumber(of display: DisplayID) -> Int? {
        guard displayIDs.contains(display) else {
            return nil
        }
        return (1...displayIDs.count).first { self.display(numbered: $0) == display }
    }
}

public func workspaceBarState(manager: WorkspaceManager, registry: WindowRegistry) -> WorkspaceBarState {
    let numbered = manager.displayIDs
        .map { (number: manager.displayNumber(of: $0) ?? 0, id: $0) }
        .sorted { $0.number < $1.number }
    var entries: [WorkspaceBarEntry] = []
    for display in numbered {
        let active = manager.activeID(on: display.id)
        let isFocusedDisplay = display.id == manager.focusedDisplay
        for (offset, workspace) in manager.stack(on: display.id).enumerated() {
            let definition = workspace.name.flatMap { name in manager.namedDefinitions.first { $0.name == name } }
            let windows = workspace.columns.flatMap(\.windows).compactMap { registry.find($0) }
            var apps: [String] = []
            for window in windows where !apps.contains(window.application) {
                apps.append(window.application)
            }
            let visible = workspace.id == active
            entries.append(WorkspaceBarEntry(
                display: display.number, index: offset + 1, name: workspace.name,
                icon: definition?.icon, color: definition?.color, windows: windows.count, apps: apps,
                focused: visible && isFocusedDisplay, visible: visible
            ))
        }
    }
    return WorkspaceBarState(
        focusedDisplay: manager.displayNumber(of: manager.focusedDisplay) ?? 1,
        focusedWorkspace: manager.current,
        focusedName: manager.currentWorkspace().name,
        workspaces: entries
    )
}

/// SB-01: which hooks a new snapshot fires. `workspace`: the focused
/// display, its active workspace or any display's shown workspace changed;
/// `windows`: a workspace's window count, apps, name, icon or color changed,
/// or the stacks changed shape. The first snapshot (`previous == nil`) fires
/// both, so a bar starts in sync.
public struct WorkspaceBarChange: Equatable, Sendable {
    public var workspace: Bool
    public var windows: Bool

    public init(workspace: Bool, windows: Bool) {
        self.workspace = workspace
        self.windows = windows
    }
}

public func diffWorkspaceBar(previous: WorkspaceBarState?, current: WorkspaceBarState) -> WorkspaceBarChange {
    guard let previous else {
        return WorkspaceBarChange(workspace: true, windows: true)
    }
    struct Shown: Equatable {
        let display: Int
        let index: Int
    }
    struct Contents: Equatable {
        let display: Int
        let index: Int
        let name: String?
        let icon: String?
        let color: String?
        let windows: Int
        let apps: [String]
    }
    func shown(_ state: WorkspaceBarState) -> [Shown] {
        state.workspaces.filter(\.visible).map { Shown(display: $0.display, index: $0.index) }
    }
    func contents(_ state: WorkspaceBarState) -> [Contents] {
        state.workspaces.map {
            Contents(
                display: $0.display, index: $0.index, name: $0.name, icon: $0.icon, color: $0.color,
                windows: $0.windows, apps: $0.apps
            )
        }
    }
    let workspace = previous.focusedDisplay != current.focusedDisplay
        || previous.focusedWorkspace != current.focusedWorkspace
        || previous.focusedName != current.focusedName
        || shown(previous) != shown(current)
    return WorkspaceBarChange(workspace: workspace, windows: contents(previous) != contents(current))
}

/// `gio list-workspaces --json`: one object per workspace, keys sorted.
public func encodeWorkspaceBarJSON(_ state: WorkspaceBarState) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(state.workspaces), let text = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return text
}

/// SB-01: what a hook's shell sees: the inherited environment plus the
/// focused workspace (`GIO_FOCUSED_WORKSPACE`, its position on the focused
/// display), its name (empty for a dynamic one), the one focused before the
/// last workspace change (empty until there is one) and the focused
/// display's number. An app opened from Finder inherits a bare PATH, so
/// `~/.local/bin` (the `gio` link), Homebrew and `/usr/local/bin` are put in
/// front of it when missing.
public func hookEnvironment(
    base: [String: String], state: WorkspaceBarState, previousWorkspace: Int?, home: String
) -> [String: String] {
    var environment = base
    environment["GIO_FOCUSED_WORKSPACE"] = String(state.focusedWorkspace)
    environment["GIO_FOCUSED_WORKSPACE_NAME"] = state.focusedName ?? ""
    environment["GIO_PREV_WORKSPACE"] = previousWorkspace.map(String.init) ?? ""
    environment["GIO_DISPLAY"] = String(state.focusedDisplay)
    let path = base["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let entries = path.split(separator: ":").map(String.init)
    let missing = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].filter { !entries.contains($0) }
    environment["PATH"] = (missing + [path]).joined(separator: ":")
    return environment
}

/// SB-01: one hook's run slot. At most one run is in flight; changes while
/// it runs fold into a single rerun, which reads the state current when it
/// starts (the latest).
public struct HookFlight: Equatable, Sendable {
    public private(set) var isRunning = false
    public private(set) var isPending = false

    public init() {}

    /// A change wants the hook to run: true when it starts now.
    public mutating func request() -> Bool {
        guard !isRunning else {
            isPending = true
            return false
        }
        isRunning = true
        return true
    }

    /// The run ended: true when the queued rerun starts now.
    public mutating func finish() -> Bool {
        guard isPending else {
            isRunning = false
            return false
        }
        isPending = false
        return true
    }
}
