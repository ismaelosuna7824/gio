import Foundation

/// Persistent, batched, size-rotated file sink behind `GioLog`.
///
/// One `FileHandle` stays open; lines are queued in memory and written on a
/// private utility-QoS serial queue, either when `maxBatch` lines are pending
/// or `flushDelay` after the first pending line. `flush()` drains
/// synchronously (shutdown, tests, readers). When the file reaches
/// `maxBytes` it is renamed to `<path>.1` (one backup) and reopened.
/// Best-effort: disk failures stay silent, logging never throws.
final class LogFileSink: @unchecked Sendable {
    let path: String
    private let maxBytes: UInt64
    private let maxBatch: Int
    private let flushDelay: TimeInterval
    private let queue = DispatchQueue(label: "gio.log.sink", qos: .utility)
    private let lock = NSLock()
    private var pending: [String] = []
    private var flushScheduled = false
    // Touched only on `queue`.
    private var handle: FileHandle?
    private var size: UInt64 = 0

    init(path: String, maxBytes: UInt64 = 1_000_000, maxBatch: Int = 32, flushDelay: TimeInterval = 0.1) {
        self.path = path
        self.maxBytes = maxBytes
        self.maxBatch = max(1, maxBatch)
        self.flushDelay = flushDelay
    }

    /// Queue one complete line (newline included by the sink). `immediate`
    /// skips the batching delay (warn/error should reach disk promptly).
    func append(_ line: String, immediate: Bool = false) {
        lock.lock()
        pending.append(line)
        let full = pending.count >= maxBatch
        let needsTimer = !flushScheduled && !(full || immediate)
        if needsTimer {
            flushScheduled = true
        }
        lock.unlock()
        if full || immediate {
            queue.async { [self] in drain() }
        } else if needsTimer {
            queue.asyncAfter(deadline: .now() + flushDelay) { [self] in drain() }
        }
    }

    /// Write everything pending, synchronously.
    func flush() {
        queue.sync { drain() }
    }

    /// Flush and close the handle (path change, tests).
    func close() {
        queue.sync {
            drain()
            try? handle?.close()
            handle = nil
        }
    }

    private func drain() {
        lock.lock()
        let lines = pending
        pending = []
        flushScheduled = false
        lock.unlock()
        guard !lines.isEmpty else {
            return
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard ensureHandle() else {
            return
        }
        if size > 0, size + UInt64(data.count) > maxBytes {
            rotate()
            guard ensureHandle() else {
                return
            }
        }
        do {
            try handle?.write(contentsOf: data)
            size += UInt64(data.count)
        } catch {
            try? handle?.close()
            handle = nil
        }
    }

    /// Open (or reopen when the file vanished) the append handle.
    private func ensureHandle() -> Bool {
        let fm = FileManager.default
        if handle != nil, fm.fileExists(atPath: path) {
            return true
        }
        try? handle?.close()
        handle = nil
        do {
            let url = URL(fileURLWithPath: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil)
            }
            let opened = try FileHandle(forWritingTo: url)
            size = try opened.seekToEnd()
            handle = opened
            return true
        } catch {
            return false
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let backup = path + ".1"
        try? fm.removeItem(atPath: backup)
        try? fm.moveItem(atPath: path, toPath: backup)
        size = 0
    }
}
