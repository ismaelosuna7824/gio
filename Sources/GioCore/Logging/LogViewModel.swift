import Foundation

/// Filter behind the Logs section: severity threshold plus free text.
public struct LogFilter: Equatable, Sendable {
    public var minLevel: LogLevel
    public var search: String

    public init(minLevel: LogLevel = .info, search: String = "") {
        self.minLevel = minLevel
        self.search = search
    }

    /// Entries at `minLevel` or above whose message or level name contains
    /// the search text (case-insensitive). Blank search matches everything.
    public func apply(to entries: [LogEntry]) -> [LogEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            guard entry.level >= minLevel else {
                return false
            }
            return needle.isEmpty
                || entry.message.lowercased().contains(needle)
                || entry.level.name.contains(needle)
        }
    }
}

/// Lines this store wrote, parsed; anything else is skipped.
public func parseLogEntries(_ text: String) -> [LogEntry] {
    text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
        LogEntry.parse(String($0))
    }
}

public func logFileSize(path: String = GioLog.logFilePath) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
}

/// Entries of the log file from `fromOffset` (the size recorded when the
/// user cleared the view) to the end, at most the last `maxBytes`. A
/// partial first line produced by the byte cut is dropped.
public func readLogEntries(
    path: String = GioLog.logFilePath, fromOffset: UInt64 = 0, maxBytes: UInt64 = 256 * 1024
) -> [LogEntry] {
    guard let handle = FileHandle(forReadingAtPath: path) else {
        return []
    }
    defer { try? handle.close() }
    let size = logFileSize(path: path)
    guard size > fromOffset else {
        return []
    }
    let start = max(fromOffset, size > maxBytes ? size - maxBytes : 0)
    do {
        try handle.seek(toOffset: start)
        guard let data = try handle.readToEnd(), var text = String(data: data, encoding: .utf8) else {
            return []
        }
        // Cut mid-file: the first line may be partial.
        if start > fromOffset, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return parseLogEntries(text)
    } catch {
        return []
    }
}
