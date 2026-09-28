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
        let levelName = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
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
public enum GioLog {
    private static let store = LogStore()
    public nonisolated(unsafe) static var logFilePath: String =
        FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/gio.log"

    public static func record(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(timestamp: isoNow(), level: level, message: message)
        store.append(entry)
        let line = entry.line() + "\n"
        guard let data = line.data(using: .utf8) else {
            return
        }
        do {
            let url = URL(fileURLWithPath: logFilePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: logFilePath) {
                let handle = try FileHandle(forWritingTo: url)
                defer {
                    try? handle.close()
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // Logging is best-effort: disk failures stay silent by design.
        }
    }

    public static func entries(minLevel: LogLevel = .trace) -> [LogEntry] {
        store.read(minLevel: minLevel)
    }

    public static func readFile(minLevel: LogLevel = .trace, path: String? = nil) -> [String] {
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
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
