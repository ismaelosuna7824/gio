import Foundation

/// Persistent, batched, size-rotated file sink behind `GioLog`.
///
/// Lines are queued in memory and written on a private utility-QoS serial
/// queue, either when `maxBatch` lines are pending or `flushDelay` after the
/// first pending line. `flush()` drains synchronously (shutdown, tests,
/// readers). Best-effort: disk failures stay silent, logging never throws.
///
/// Cross-process safety: Gio and its guardian (`Gio --guardian`) append to
/// the same file. The descriptor is opened with `O_APPEND` and each batch is
/// ONE `write(2)` of complete lines, so the kernel places every batch at the
/// current end of file and lines of the two processes never splice (there
/// is no seek-then-write). Only a `rotates` sink (the main process) renames
/// the file to `<path>.1` when it reaches `maxBytes` (measured on the file,
/// so the other writer's lines count); every sink compares its descriptor
/// with the path before each batch and reopens when the file was renamed or
/// removed, so a non-rotating writer follows the rotation instead of
/// writing into the backup.
final class LogFileSink: @unchecked Sendable {
    let path: String
    private let maxBytes: UInt64
    private let maxBatch: Int
    private let flushDelay: TimeInterval
    private let rotates: Bool
    private let queue = DispatchQueue(label: "gio.log.sink", qos: .utility)
    private let lock = NSLock()
    private var pending: [String] = []
    private var flushScheduled = false
    // Touched only on `queue`.
    private var descriptor: Int32 = -1

    init(
        path: String, maxBytes: UInt64 = 1_000_000, maxBatch: Int = 32, flushDelay: TimeInterval = 0.1,
        rotates: Bool = true
    ) {
        self.path = path
        self.maxBytes = maxBytes
        self.maxBatch = max(1, maxBatch)
        self.flushDelay = flushDelay
        self.rotates = rotates
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
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

    /// Flush and close the descriptor (path change, tests).
    func close() {
        queue.sync {
            drain()
            closeDescriptor()
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
        let bytes = Array((lines.joined(separator: "\n") + "\n").utf8)
        guard ensureDescriptor() else {
            return
        }
        if rotates, let size = currentSize(), size > 0, size + UInt64(bytes.count) > maxBytes {
            rotate()
            guard ensureDescriptor() else {
                return
            }
        }
        if !writeWhole(bytes) {
            closeDescriptor()
        }
    }

    /// One `write(2)` for the batch; a short write (disk full, signal)
    /// finishes the remainder so no line is left half written.
    private func writeWhole(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { buffer -> Bool in
            guard var base = buffer.baseAddress else {
                return true
            }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, base, remaining)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                remaining -= written
                base += written
            }
            return true
        }
    }

    /// Open (or reopen when the path now names another file, or none) the
    /// append descriptor.
    private func ensureDescriptor() -> Bool {
        if descriptor >= 0, descriptorMatchesPath() {
            return true
        }
        closeDescriptor()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let opened = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard opened >= 0 else {
            return false
        }
        descriptor = opened
        return true
    }

    /// Same device and inode behind the path and the descriptor.
    private func descriptorMatchesPath() -> Bool {
        var onDisk = stat()
        var open = stat()
        guard stat(path, &onDisk) == 0, fstat(descriptor, &open) == 0 else {
            return false
        }
        return onDisk.st_dev == open.st_dev && onDisk.st_ino == open.st_ino
    }

    private func currentSize() -> UInt64? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            return nil
        }
        return UInt64(info.st_size)
    }

    private func closeDescriptor() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    /// Main process only: keep one backup, start a fresh file.
    private func rotate() {
        closeDescriptor()
        let fm = FileManager.default
        let backup = path + ".1"
        try? fm.removeItem(atPath: backup)
        try? fm.moveItem(atPath: path, toPath: backup)
    }
}
