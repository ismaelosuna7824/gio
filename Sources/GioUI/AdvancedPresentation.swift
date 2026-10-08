import Foundation
import GioCore

/// DD-04 pure presentation logic for Shortcuts, Logs and Diagnostics.
/// Views only draw what these return.

// MARK: - Shortcuts

/// A category chip above the shortcut list.
public enum ShortcutChip: Hashable, Sendable {
    case all
    case category(ShortcutCategory)

    public static let allChips: [ShortcutChip] = [.all] + ShortcutCategory.allCases.map { .category($0) }

    public var title: String {
        switch self {
        case .all: return "All"
        case .category(let category): return category.title
        }
    }

    func includes(_ category: ShortcutCategory) -> Bool {
        switch self {
        case .all: return true
        case .category(let chosen): return chosen == category
        }
    }
}

public struct ShortcutSection: Equatable, Sendable, Identifiable {
    public let category: ShortcutCategory
    public let entries: [ShortcutEntry]
    public var id: String { category.title }
}

/// Entries matching the chip and query, one section per non-empty
/// category in display order.
public func shortcutSections(_ entries: [ShortcutEntry], chip: ShortcutChip, query: String) -> [ShortcutSection] {
    let matches = filterShortcuts(entries, query: query)
    return ShortcutCategory.allCases.filter(chip.includes).compactMap { category in
        let rows = matches.filter { $0.category == category }
        return rows.isEmpty ? nil : ShortcutSection(category: category, entries: rows)
    }
}

/// How many actions a chip holds for the current query.
public func shortcutChipCount(_ entries: [ShortcutEntry], chip: ShortcutChip, query: String) -> Int {
    filterShortcuts(entries, query: query).filter { chip.includes($0.category) }.count
}

/// Bindings as a row shows them: a long parameterized family
/// (`workspace 1…9`) reads as its first and last combo with an ellipsis.
public struct CompactBindings: Equatable, Sendable {
    public let shown: [ShortcutBinding]
    public let isRange: Bool
}

public func compactBindings(_ bindings: [ShortcutBinding]) -> CompactBindings {
    guard bindings.count > 3, let first = bindings.first, let last = bindings.last else {
        return CompactBindings(shown: bindings, isRange: false)
    }
    return CompactBindings(shown: [first, last], isRange: true)
}

// MARK: - Logs

/// Consecutive identical lines (same level and message) shown once, ×N.
public struct LogGroup: Equatable, Sendable, Identifiable {
    /// Position of the group's first line in the entries it came from.
    public let id: Int
    public let level: LogLevel
    public let message: String
    public let count: Int
    public let firstTimestamp: String
    public let lastTimestamp: String
}

public func groupLogEntries(_ entries: [LogEntry]) -> [LogGroup] {
    var groups: [LogGroup] = []
    for (index, entry) in entries.enumerated() {
        if let last = groups.last, last.level == entry.level, last.message == entry.message {
            groups[groups.count - 1] = LogGroup(
                id: last.id, level: last.level, message: last.message, count: last.count + 1,
                firstTimestamp: last.firstTimestamp, lastTimestamp: entry.timestamp
            )
        } else {
            groups.append(LogGroup(
                id: index, level: entry.level, message: entry.message, count: 1,
                firstTimestamp: entry.timestamp, lastTimestamp: entry.timestamp
            ))
        }
    }
    return groups
}

/// Level chips (any combination) plus free-text search.
public struct LogLevelFilter: Equatable, Sendable {
    public var levels: Set<LogLevel>
    public var search: String

    public init(levels: Set<LogLevel> = [.info, .warn, .error], search: String = "") {
        self.levels = levels
        self.search = search
    }

    public mutating func toggle(_ level: LogLevel) {
        if levels.contains(level) {
            levels.remove(level)
        } else {
            levels.insert(level)
        }
    }

    public func apply(to entries: [LogEntry]) -> [LogEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            levels.contains(entry.level) && (needle.isEmpty || entry.message.lowercased().contains(needle))
        }
    }
}

public func logLevelCounts(_ entries: [LogEntry]) -> [LogLevel: Int] {
    entries.reduce(into: [:]) { $0[$1.level, default: 0] += 1 }
}

/// What "Copy visible" puts on the pasteboard: one line per group, repeats
/// marked "(×N)".
public func logCopyText(_ groups: [LogGroup]) -> String {
    groups.map { group in
        let line = LogEntry(timestamp: group.lastTimestamp, level: group.level, message: group.message).line()
        return group.count > 1 ? "\(line) (×\(group.count))" : line
    }.joined(separator: "\n")
}

/// ISO8601DateFormatter is thread-safe for parsing.
private nonisolated(unsafe) let logTimestampParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

func parseLogTimestamp(_ timestamp: String) -> Date? {
    logTimestampParser.date(from: timestamp)
}

/// "now", "30s ago", "5m ago", "3h ago", "3d ago"; nil when unparseable.
public func relativeLogTime(_ timestamp: String, now: Date) -> String? {
    guard let date = parseLogTimestamp(timestamp) else {
        return nil
    }
    let seconds = Int(now.timeIntervalSince(date))
    switch seconds {
    case ..<5: return "now"
    case ..<60: return "\(seconds)s ago"
    case ..<3600: return "\(seconds / 60)m ago"
    case ..<86_400: return "\(seconds / 3600)h ago"
    default: return "\(seconds / 86_400)d ago"
    }
}

/// Local, readable absolute time for the hover tooltip.
func absoluteLogTime(_ timestamp: String) -> String {
    guard let date = parseLogTimestamp(timestamp) else {
        return timestamp
    }
    return date.formatted(date: .abbreviated, time: .standard)
}

// MARK: - Diagnostics

/// One checklist card on the Diagnostics page.
public struct DiagnosticCheck: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let tint: SectionTint
    public let status: StatusKind
    public let badge: String
    public let summary: String
    public let details: [String]
}

private func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

public func diagnosticChecklist(
    facts: SessionFacts, config: GioConfig, version: String, build: String?,
    socketPath: String, socketExists: Bool, logPath: String
) -> [DiagnosticCheck] {
    let wantsSnapshot = config.animations.enabled && config.animations.renderer == .snapshot

    let permissions: DiagnosticCheck
    let permissionDetails = [
        "Accessibility: \(facts.accessibilityGranted ? "granted" : "missing")",
        "Screen Recording: \(facts.screenRecordingGranted ? "granted" : "not granted")",
    ]
    if !facts.accessibilityGranted {
        permissions = DiagnosticCheck(
            id: "permissions", title: "Permissions", symbol: "hand.raised.fill", tint: .blue, status: .error,
            badge: "Accessibility missing",
            summary: "Gio cannot move windows or hear shortcuts until Accessibility is granted.",
            details: permissionDetails
        )
    } else if !facts.screenRecordingGranted, wantsSnapshot {
        permissions = DiagnosticCheck(
            id: "permissions", title: "Permissions", symbol: "hand.raised.fill", tint: .blue, status: .warning,
            badge: "Screen Recording missing",
            summary: "The snapshot renderer needs Screen Recording; relaunch Gio after granting it.",
            details: permissionDetails
        )
    } else {
        permissions = DiagnosticCheck(
            id: "permissions", title: "Permissions", symbol: "hand.raised.fill", tint: .blue, status: .ok,
            badge: "Granted",
            summary: facts.screenRecordingGranted
                ? "Accessibility and Screen Recording are granted."
                : "Accessibility is granted. Screen Recording is only needed by the snapshot renderer.",
            details: permissionDetails
        )
    }

    let versionLine = "Version " + (build.map { "\(version) (build \($0))" } ?? version)
    let session = DiagnosticCheck(
        id: "session", title: "Session", symbol: "bolt.fill", tint: .green,
        status: socketExists ? .ok : .error, badge: socketExists ? "Running" : "No CLI socket",
        summary: socketExists
            ? "Tiling is running and the gio command-line tool can connect."
            : "Tiling is running, but the gio command-line tool cannot connect.",
        details: [versionLine, "Socket \(socketPath)"]
    )

    let configuration: DiagnosticCheck
    if !facts.configExists {
        configuration = DiagnosticCheck(
            id: "configuration", title: "Configuration", symbol: "doc.badge.gearshape.fill", tint: .gray,
            status: .ok, badge: "Defaults",
            summary: "No config.toml yet; the built-in defaults are in use.", details: [facts.configPath]
        )
    } else if facts.configMessages.isEmpty {
        configuration = DiagnosticCheck(
            id: "configuration", title: "Configuration", symbol: "doc.badge.gearshape.fill", tint: .gray,
            status: .ok, badge: "Valid", summary: "config.toml parsed without problems.", details: [facts.configPath]
        )
    } else {
        configuration = DiagnosticCheck(
            id: "configuration", title: "Configuration", symbol: "doc.badge.gearshape.fill", tint: .gray,
            status: .warning, badge: plural(facts.configMessages.count, "issue"),
            summary: "Invalid values fall back to defaults; the rest of config.toml still applies.",
            details: facts.configMessages
        )
    }

    let count = facts.displays.count
    let displays = DiagnosticCheck(
        id: "displays", title: "Displays", symbol: "display", tint: .indigo,
        status: count == 0 ? .warning : .ok, badge: count == 0 ? "None" : plural(count, "display"),
        summary: count == 0 ? "No display is being tiled yet." : "Workspace \(facts.currentWorkspace) is in focus.",
        details: facts.displays.map { display in
            "Display \(display.id) · workspace \(display.workspace)"
                + (display.stack.isEmpty ? "" : " of \(display.stack.count)")
        }
    )

    let renderer: DiagnosticCheck
    if !config.animations.enabled {
        renderer = DiagnosticCheck(
            id: "renderer", title: "Renderer", symbol: "wand.and.stars", tint: .pink, status: .neutral,
            badge: "Off", summary: "Animations are off; windows move instantly.", details: []
        )
    } else if effectiveRenderer(config: config.animations, permission: facts.screenRecordingGranted) == .snapshot {
        renderer = DiagnosticCheck(
            id: "renderer", title: "Renderer", symbol: "wand.and.stars", tint: .pink, status: .ok,
            badge: "Snapshot",
            summary: "Slides window images at the display's refresh rate, then places the windows once.", details: []
        )
    } else if wantsSnapshot {
        renderer = DiagnosticCheck(
            id: "renderer", title: "Renderer", symbol: "wand.and.stars", tint: .pink, status: .warning,
            badge: "Fallback",
            summary: "Snapshot is selected but Screen Recording is missing, so windows move through Accessibility.",
            details: []
        )
    } else {
        renderer = DiagnosticCheck(
            id: "renderer", title: "Renderer", symbol: "wand.and.stars", tint: .pink, status: .ok,
            badge: "Accessibility", summary: "Windows animate live through Accessibility.", details: []
        )
    }

    let logging = DiagnosticCheck(
        id: "logging", title: "Logging", symbol: "doc.text.fill", tint: .teal, status: .ok, badge: "Writing",
        summary: "Events, counts and timings; never window titles.", details: [logPath]
    )

    return [permissions, session, configuration, displays, renderer, logging]
}

/// "Test Snapshot Capture" only makes sense while the snapshot renderer
/// is the one in use.
public func showsSnapshotCaptureTest(config: GioConfig, screenRecording: Bool) -> Bool {
    config.animations.enabled && effectiveRenderer(config: config.animations, permission: screenRecording) == .snapshot
}
