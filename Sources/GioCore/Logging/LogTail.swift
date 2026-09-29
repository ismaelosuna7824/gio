import Foundation

/// Incremental reader behind the Logs view: remembers the byte offset it
/// consumed, so a poll costs one `stat` when nothing was appended and reads
/// only the new bytes otherwise. A new file identity (rotation) or a smaller
/// size (truncation) restarts from the top of the current file. Only whole
/// lines are consumed; a half-written last line waits for its newline.
public struct LogTail {
    public private(set) var entries: [LogEntry] = []
    private let path: String
    private let maxEntries: Int
    private let initialBytes: UInt64
    private var offset: UInt64 = 0
    private var fileNumber: UInt64?
    private var started = false

    public init(
        path: String = GioLog.logFilePath, maxEntries: Int = 500, initialBytes: UInt64 = 256 * 1024
    ) {
        self.path = path
        self.maxEntries = max(1, maxEntries)
        self.initialBytes = initialBytes
    }

    /// Hide everything already in the file (view-only; nothing is deleted).
    public mutating func clear() {
        entries = []
        let (size, number) = stat()
        offset = size
        fileNumber = number
        started = true
    }

    /// Read new complete lines. True when `entries` changed.
    @discardableResult
    public mutating func poll() -> Bool {
        let (size, number) = stat()
        guard let number else {
            return false
        }
        var restarted = false
        if started, number != fileNumber || size < offset {
            offset = 0
            restarted = true
        }
        fileNumber = number
        var partialFirstLine = false
        if !started {
            started = true
            if size > initialBytes {
                offset = size - initialBytes
                partialFirstLine = true
            }
        }
        _ = restarted
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset)),
              !data.isEmpty
        else {
            return false
        }
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return false
        }
        var chunk = data[data.startIndex...lastNewline]
        offset += UInt64(chunk.count)
        if partialFirstLine, let firstNewline = chunk.firstIndex(of: 0x0A) {
            chunk = chunk[chunk.index(after: firstNewline)...]
        }
        let fresh = parseLogEntries(String(decoding: chunk, as: UTF8.self))
        guard !fresh.isEmpty else {
            return false
        }
        entries.append(contentsOf: fresh)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        return true
    }

    private func stat() -> (size: UInt64, number: UInt64?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return (0, nil)
        }
        return (
            (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}
