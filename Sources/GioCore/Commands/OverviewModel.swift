import Foundation

/// One managed window as the host saw it on the session queue. Plain values
/// so the mapping below stays pure and testable.
public struct WindowFact: Equatable, Sendable {
    public let id: String
    public let application: String
    public let title: String
    public let workspace: Int?
    public let mode: WindowMode
    public let floatReason: FloatReason?
    public let isMinimized: Bool
    /// False when no display currently shows the window's workspace.
    public let workspaceIsShown: Bool

    public init(
        id: String, application: String, title: String, workspace: Int?, mode: WindowMode,
        floatReason: FloatReason?, isMinimized: Bool, workspaceIsShown: Bool
    ) {
        self.id = id
        self.application = application
        self.title = title
        self.workspace = workspace
        self.mode = mode
        self.floatReason = floatReason
        self.isMinimized = isMinimized
        self.workspaceIsShown = workspaceIsShown
    }
}

public struct DisplayFact: Equatable, Sendable {
    public let id: UInt32
    /// Index of the display's active workspace in its own stack.
    public let workspace: Int
    /// The display's whole dynamic stack (NF-02); empty when unknown.
    public let stack: [WorkspaceEntry]

    public init(id: UInt32, workspace: Int, stack: [WorkspaceEntry] = []) {
        self.id = id
        self.workspace = workspace
        self.stack = stack
    }
}

/// Everything the Overview needs, captured in one pass.
public struct SessionFacts: Equatable, Sendable {
    public let configPath: String
    public let configExists: Bool
    public let configMessages: [String]
    /// S6: config.toml had errors and was ignored as a whole (defaults run);
    /// `configMessages` are then errors, otherwise warnings of a file that applies.
    public let configRejected: Bool
    public let accessibilityGranted: Bool
    /// SM-01: `CGPreflightScreenCaptureAccess()`; needed by the snapshot renderer.
    public let screenRecordingGranted: Bool
    public let currentWorkspace: Int
    public let displays: [DisplayFact]
    public let windows: [WindowFact]
    /// DD-02: the focused display's current workspace as a strip, for the
    /// Overview miniature; nil when no layout was available.
    public let strip: WorkspaceStripFact?
    /// TG-03: whether trackpad gestures run, and why.
    public let gestures: GestureSourceStatus
    /// TG-04: Gio's gestures that macOS performs too (system swipes on).
    public let gestureConflicts: [GestureConflict]

    public init(
        configPath: String, configExists: Bool, configMessages: [String], configRejected: Bool = false,
        accessibilityGranted: Bool, currentWorkspace: Int,
        displays: [DisplayFact], windows: [WindowFact], screenRecordingGranted: Bool = false,
        strip: WorkspaceStripFact? = nil,
        gestures: GestureSourceStatus = GestureSourceStatus(available: false, reason: "unknown"),
        gestureConflicts: [GestureConflict] = []
    ) {
        self.gestures = gestures
        self.gestureConflicts = gestureConflicts
        self.configPath = configPath
        self.configExists = configExists
        self.configMessages = configMessages
        self.configRejected = configRejected
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.currentWorkspace = currentWorkspace
        self.displays = displays
        self.windows = windows
        self.strip = strip
    }
}

public enum WindowState: Equatable, Sendable {
    case tiled
    case floating(FloatReason?)
    case fullscreen
    case minimized
    case hidden

    public var label: String {
        switch self {
        case .tiled: return "Tiled"
        case .fullscreen: return "Fullscreen"
        case .minimized: return "Minimized"
        case .hidden: return "Hidden (other workspace)"
        case .floating(let reason):
            guard let reason else {
                return "Floating"
            }
            switch reason {
            case .dialog: return "Floating (dialog)"
            case .floatingSubrole: return "Floating (floating panel)"
            case .notResizable: return "Floating (not resizable)"
            case .rule: return "Floating (window rule)"
            case .manual: return "Floating (toggled)"
            case .appControlled: return "Floating (app keeps its frame)"
            }
        }
    }
}

public struct WindowRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let application: String
    public let title: String
    public let workspace: Int?
    public let state: WindowState
}

public struct Overview: Equatable, Sendable {
    public let configSummary: String
    public let configIssues: [String]
    public let accessibilityGranted: Bool
    public let screenRecordingGranted: Bool
    public let displayLines: [String]
    public let windows: [WindowRow]
    public let windowSummary: String
    /// TG-04: Gio gestures macOS performs too, with where to change them.
    public var gestureWarnings: [String] = []
}

/// Minimized wins over hidden, hidden over the window's own mode: what the
/// user can actually do with the window right now.
public func windowRows(_ facts: [WindowFact]) -> [WindowRow] {
    let rows = facts.map { fact -> WindowRow in
        let state: WindowState
        if fact.isMinimized {
            state = .minimized
        } else if !fact.workspaceIsShown {
            state = .hidden
        } else {
            switch fact.mode {
            case .tiled: state = .tiled
            case .floating: state = .floating(fact.floatReason)
            case .fullscreen: state = .fullscreen
            }
        }
        return WindowRow(
            id: fact.id, application: fact.application,
            title: fact.title.isEmpty ? "(untitled)" : fact.title,
            workspace: fact.workspace, state: state
        )
    }
    return rows.sorted { lhs, rhs in
        switch (lhs.workspace, rhs.workspace) {
        case let (l?, r?) where l != r: return l < r
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        let apps = lhs.application.localizedCaseInsensitiveCompare(rhs.application)
        if apps != .orderedSame {
            return apps == .orderedAscending
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

/// `6 windows: 2 tiled, 1 floating, …` — zero counts omitted.
public func windowSummary(_ rows: [WindowRow]) -> String {
    guard !rows.isEmpty else {
        return "No windows managed"
    }
    let parts: [(String, (WindowState) -> Bool)] = [
        ("tiled", { $0 == .tiled }),
        ("floating", { if case .floating = $0 { return true } else { return false } }),
        ("fullscreen", { $0 == .fullscreen }),
        ("minimized", { $0 == .minimized }),
        ("hidden", { $0 == .hidden }),
    ]
    let counts = parts.compactMap { name, matches -> String? in
        let count = rows.filter { matches($0.state) }.count
        return count > 0 ? "\(count) \(name)" : nil
    }
    let noun = rows.count == 1 ? "window" : "windows"
    return "\(rows.count) \(noun): " + counts.joined(separator: ", ")
}

public func makeOverview(_ facts: SessionFacts) -> Overview {
    let configSummary: String
    if !facts.configMessages.isEmpty {
        let count = facts.configMessages.count
        configSummary = "\(count) \(count == 1 ? "issue" : "issues") in \(facts.configPath)"
    } else if facts.configExists {
        configSummary = "Valid: \(facts.configPath)"
    } else {
        configSummary = "No config file, using defaults (\(facts.configPath))"
    }
    let displayLines: [String]
    if facts.displays.isEmpty {
        displayLines = ["Current workspace: \(facts.currentWorkspace)"]
    } else {
        displayLines = facts.displays.sorted { $0.id < $1.id }.enumerated().flatMap { index, display in
            var lines = ["Display \(index + 1): workspace \(display.workspace)"]
            if !display.stack.isEmpty {
                lines.append("Stack: " + display.stack.map { entry in
                    (entry.isActive ? "▸" : "") + entry.label
                }.joined(separator: " · "))
            }
            return lines
        }
    }
    let rows = windowRows(facts.windows)
    return Overview(
        configSummary: configSummary, configIssues: facts.configMessages,
        accessibilityGranted: facts.accessibilityGranted,
        screenRecordingGranted: facts.screenRecordingGranted, displayLines: displayLines,
        windows: rows, windowSummary: windowSummary(rows),
        gestureWarnings: facts.gestureConflicts.map(gestureConflictMessage)
    )
}
