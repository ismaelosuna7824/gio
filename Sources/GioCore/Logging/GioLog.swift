import Foundation

/// Plan §31 logging. Severity order: trace < debug < info < warn < error.
/// Two sinks: an in-memory ring (cap 500, for live views) and an
/// append-only file (cross-process, what `gio logs` reads). Best-effort
/// throughout — logging never throws, never blocks, never crashes.
///
/// Privacy rule: messages carry IDs and numbers, NEVER window titles.
public enum LogLevel: Int, Equatable, Sendable, Comparable, CaseIterable {
    case trace = 0
    case debug = 1
    case info = 2
    case warn = 3
    case error = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var name: String {
        switch self {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info: return "info"
        case .warn: return "warn"
        case .error: return "error"
        }
    }

    public init?(name: String) {
        let lowered = name.lowercased()
        guard let level = LogLevel.allCases.first(where: { $0.name == lowered }) else {
            return nil
        }
        self = level
    }
}

public struct LogEntry: Equatable, Sendable {
    public var timestamp: String
    public var level: LogLevel
    public var message: String

    public init(timestamp: String, level: LogLevel, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }

    public func line() -> String {
        "[\(timestamp)] [\(level.name.uppercased())] \(message)"
    }

    /// Parse back a line this store wrote. Nil for anything else.
    public static func parse(_ line: String) -> LogEntry? {
        guard line.hasPrefix("[") else {
            return nil
        }
        let parts = line.split(separator: "]", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        let timestamp = String(parts[0].dropFirst())
        var levelName = String(parts[1]).trimmingCharacters(in: .whitespaces)
        if levelName.hasPrefix("[") {
            levelName.removeFirst()
        }
        guard let level = LogLevel(name: levelName) else {
            return nil
        }
        let message = String(parts[2].dropFirst())
        return LogEntry(timestamp: timestamp, level: level, message: message)
    }
}

final class LogStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let capacity = 500

    func append(_ entry: LogEntry) {
        lock.withLock {
            entries.append(entry)
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
        }
    }

    func read(minLevel: LogLevel) -> [LogEntry] {
        lock.withLock {
            entries.filter { $0.level >= minLevel }
        }
    }

    func clear() {
        lock.withLock {
            entries = []
        }
    }
}

/// Global log. `logFilePath` is assignable so tests isolate file output;
/// production uses `~/.config/gio/gio.log`. Set once at startup (or per
/// test) and only read afterwards — hence the escape hatch, not a lock.
///
/// Lines below `minimumLevel` (default `.info`) cost one compare: the
/// message autoclosure is never evaluated. File writes go through a
/// persistent, batched, rotating `LogFileSink`; call `flush()` before exit.
public enum GioLog {
    private static let store = LogStore()
    public nonisolated(unsafe) static var logFilePath: String =
        FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/gio.log"
    /// Gio and its guardian append to the same file; only Gio rotates it.
    /// The guardian sets this to false before its first line.
    public nonisolated(unsafe) static var rotatesLogFile = true

    private struct State {
        var minimumLevel: LogLevel = .info
        var sink: LogFileSink?
        var stamp: (second: Int, text: String) = (-1, "")
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var state = State()
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Lowest severity that is recorded (ring and file).
    public static var minimumLevel: LogLevel {
        get { lock.withLock { state.minimumLevel } }
        set { lock.withLock { state.minimumLevel = newValue } }
    }

    public static func record(_ level: LogLevel, _ message: @autoclosure () -> String) {
        let sink: LogFileSink? = lock.withLock {
            guard level >= state.minimumLevel else {
                return nil
            }
            return currentSink()
        }
        guard let sink else {
            return
        }
        let entry = LogEntry(timestamp: timestamp(), level: level, message: message())
        store.append(entry)
        sink.append(entry.line(), immediate: level >= .warn)
    }

    /// Write every queued line to disk, synchronously.
    public static func flush() {
        let sink = lock.withLock { state.sink }
        sink?.flush()
    }

    public static func entries(minLevel: LogLevel = .trace) -> [LogEntry] {
        store.read(minLevel: minLevel)
    }

    public static func readFile(minLevel: LogLevel = .trace, path: String? = nil) -> [String] {
        flush()
        let resolved = path ?? logFilePath
        guard let text = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .compactMap { line -> String? in
                guard let entry = LogEntry.parse(line), entry.level >= minLevel else {
                    return nil
                }
                return line
            }
    }

    static func clearForTests() {
        store.clear()
        lock.withLock {
            state.sink?.close()
            state.sink = nil
            state.minimumLevel = .trace
        }
    }

    /// Caller holds `lock`. Rebuilds the sink when `logFilePath` changed.
    private static func currentSink() -> LogFileSink {
        if let sink = state.sink, sink.path == logFilePath {
            return sink
        }
        state.sink?.close()
        let sink = LogFileSink(path: logFilePath, rotates: rotatesLogFile)
        state.sink = sink
        return sink
    }

    /// ISO-8601 prefix cached per wall-clock second.
    private static func timestamp() -> String {
        let now = Date()
        let second = Int(now.timeIntervalSince1970)
        return lock.withLock {
            if state.stamp.second != second {
                state.stamp = (second, formatter.string(from: now))
            }
            return state.stamp.text
        }
    }
}
