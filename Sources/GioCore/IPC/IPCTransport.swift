import Darwin
import Foundation

/// Plan §22 transport: Unix domain socket with 4-byte big-endian
/// length-prefixed JSON messages (4 MiB cap). Local-only by construction —
/// no ports, no network, filesystem permissions apply.
public let ipcMaxMessageBytes: Int = 4 * 1024 * 1024

/// PA-17b: how long `sendIPCRequest` waits on each read or write by default.
/// Generous on purpose: the app answers `gio update` after up to 45 s
/// (`UpdateController.answerCLI`), and other verbs wait on the session queue.
public let ipcClientTimeout: TimeInterval = 60

/// PA-17b: how long the server waits on a connection's request read and
/// reply write (not the handler), so a peer that never sends or never reads
/// cannot hold the sequential accept loop.
public let ipcServerTimeout: TimeInterval = 5

/// PA-17b: bounds every blocking `recv`/`send` on `fd` (a timed-out call
/// fails with `EAGAIN`, thrown as `IPCError.timedOut`), and makes a write to
/// a peer that already closed fail with `EPIPE` instead of a `SIGPIPE` that
/// would kill the process.
func ipcConfigureSocket(_ fd: Int32, timeout: TimeInterval) {
    let seconds = timeout.rounded(.down)
    var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((timeout - seconds) * 1_000_000))
    let size = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

/// A failed `send`/`recv`: a socket timeout or any other I/O error.
private func ipcIOFailure(_ result: Int) -> IPCError {
    let code = errno
    return result < 0 && (code == EAGAIN || code == EWOULDBLOCK) ? .timedOut : .ioError
}

func ipcWriteAll(_ fd: Int32, _ data: Data) throws {
    var sent = 0
    try data.withUnsafeBytes { buffer in
        while sent < data.count {
            guard let base = buffer.baseAddress else {
                throw IPCError.ioError
            }
            let result = send(fd, base.advanced(by: sent), data.count - sent, 0)
            guard result > 0 else {
                throw ipcIOFailure(result)
            }
            sent += result
        }
    }
}

func ipcReadExactly(_ fd: Int32, _ count: Int) throws -> Data {
    var result = Data()
    result.reserveCapacity(count)
    var buffer = [UInt8](repeating: 0, count: min(count, 65536))
    var received = 0
    while received < count {
        let chunk = recv(fd, &buffer, min(buffer.count, count - received), 0)
        guard chunk > 0 else {
            throw ipcIOFailure(chunk)
        }
        result.append(contentsOf: buffer.prefix(chunk))
        received += chunk
    }
    return result
}

func ipcSendMessage(_ fd: Int32, _ payload: Data) throws {
    guard payload.count <= ipcMaxMessageBytes else {
        throw IPCError.messageTooLarge
    }
    var length = UInt32(payload.count).bigEndian
    let header = Data(bytes: &length, count: 4)
    try ipcWriteAll(fd, header)
    try ipcWriteAll(fd, payload)
}

func ipcReceiveMessage(_ fd: Int32) throws -> Data {
    let header = try ipcReadExactly(fd, 4)
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    guard length <= ipcMaxMessageBytes else {
        throw IPCError.messageTooLarge
    }
    return try ipcReadExactly(fd, Int(length))
}

/// Zero-filled `sockaddr_un` so long paths truncate NUL-terminated instead
/// of overflowing `sun_path`.
func ipcSocketAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { raw in
        let dst = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self)
        memset(dst, 0, 104)
        _ = path.withCString { chars in
            strncpy(dst, chars, 103)
        }
    }
    return address
}

/// The serving side. `handler` maps argv to a response; the daemon will
/// dispatch against a lock-guarded session, tests use pure closures.
/// Sequential per-connection handling — enough for a local control socket.
public final class IPCServer: @unchecked Sendable {
    private let socketPath: String
    /// PA-17b: bound on each connection's request read and reply write.
    private let timeout: TimeInterval
    private let handler: @Sendable ([String]) -> IPCResponse
    private let state = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    public init(
        socketPath: String, timeout: TimeInterval = ipcServerTimeout,
        handler: @Sendable @escaping ([String]) -> IPCResponse
    ) {
        self.socketPath = socketPath
        self.timeout = timeout
        self.handler = handler
    }

    /// Binds (unlinking a stale socket file first — crash-safe) and serves
    /// on a background thread.
    public func start() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.socketFailed(errno)
        }
        var address = ipcSocketAddress(socketPath)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw IPCError.bindFailed(code)
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw IPCError.listenFailed(code)
        }
        state.withLock {
            listenFD = fd
            running = true
        }
        GioLog.record(.info, "ipc serving \(socketPath)")
        Thread.detachNewThread { [weak self] in
            self?.serve()
        }
    }

    public func stop() {
        state.withLock {
            running = false
            if listenFD >= 0 {
                // Shutting down (not just closing) unblocks a pending accept.
                shutdown(listenFD, SHUT_RDWR)
                close(listenFD)
                listenFD = -1
            }
        }
        unlink(socketPath)
    }

    private func isRunning() -> Bool {
        state.withLock { running }
    }

    private func serve() {
        while isRunning() {
            let fd: Int32 = state.withLock { listenFD }
            guard fd >= 0 else {
                break
            }
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else {
                let delay = ipcAcceptRetryDelay(errno: errno)
                if delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                }
                continue
            }
            ipcConfigureSocket(conn, timeout: timeout)
            serveConnection(conn)
            close(conn)
        }
    }

    private func serveConnection(_ fd: Int32) {
        let response: IPCResponse
        do {
            let payload = try ipcReceiveMessage(fd)
            guard let request = try? JSONDecoder().decode(IPCRequest.self, from: payload) else {
                response = IPCResponse(ok: false, error: "malformed request")
                try? ipcSendMessage(fd, JSONEncoder().encode(response))
                return
            }
            response = handler(request.argv)
        } catch {
            response = IPCResponse(ok: false, error: "unreadable request")
        }
        try? ipcSendMessage(fd, JSONEncoder().encode(response))
    }
}

/// One-shot client used by the `gio` executable. PA-17b: each read and write
/// waits at most `timeout` seconds, then throws `IPCError.timedOut`.
public func sendIPCRequest(
    _ argv: [String], socketPath: String, timeout: TimeInterval = ipcClientTimeout
) throws -> IPCResponse {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw IPCError.socketFailed(errno)
    }
    defer {
        close(fd)
    }
    ipcConfigureSocket(fd, timeout: timeout)
    var address = ipcSocketAddress(socketPath)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        throw IPCError.connectFailed(errno)
    }
    try ipcSendMessage(fd, JSONEncoder().encode(IPCRequest(argv: argv)))
    let payload = try ipcReceiveMessage(fd)
    guard let response = try? JSONDecoder().decode(IPCResponse.self, from: payload) else {
        throw IPCError.decodeFailed
    }
    return response
}

/// PF-Y: how long the accept loop waits after `accept` failed with `errno`.
/// An interrupted or aborted connection is retried at once; anything else
/// (out of descriptors or buffers) may last, so the loop waits instead of
/// spinning a thread at full speed.
public func ipcAcceptRetryDelay(errno code: Int32) -> TimeInterval {
    switch code {
    case EINTR, ECONNABORTED:
        return 0
    default:
        return 0.1
    }
}
