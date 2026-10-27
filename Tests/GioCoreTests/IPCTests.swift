import Darwin
import XCTest
@testable import GioCore

/// Plan §22: socket round-trips, framing, failures, status JSON.
final class IPCTests: XCTestCase {
    private func tempSocket() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-ipc-test-\(UUID().uuidString).sock").path
    }

    private func openRaw(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.socketFailed(errno)
        }
        var address = ipcSocketAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw IPCError.connectFailed(errno)
        }
        return fd
    }

    func testRoundTrip() throws {
        let path = tempSocket()
        let server = IPCServer(socketPath: path) { argv in
            IPCResponse(ok: true, output: argv.joined(separator: " "))
        }
        try server.start()
        defer {
            server.stop()
        }
        let response = try sendIPCRequest(["focus", "left"], socketPath: path)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.output, "focus left")
    }

    func testMultilineOutputSurvivesFraming() throws {
        let path = tempSocket()
        let body = (0..<200).map { "line\($0)" }.joined(separator: "\n")
        let server = IPCServer(socketPath: path) { _ in
            IPCResponse(ok: true, output: body)
        }
        try server.start()
        defer {
            server.stop()
        }
        let response = try sendIPCRequest(["list-windows"], socketPath: path)
        XCTAssertEqual(response.output, body)
    }

    func testMalformedRequestGetsErrorEnvelope() throws {
        let path = tempSocket()
        let server = IPCServer(socketPath: path) { _ in
            IPCResponse(ok: true)
        }
        try server.start()
        defer {
            server.stop()
        }
        let raw = try openRaw(path)
        defer {
            close(raw)
        }
        try ipcSendMessage(raw, Data("not json".utf8))
        let payload = try ipcReceiveMessage(raw)
        let response = try JSONDecoder().decode(IPCResponse.self, from: payload)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "malformed request")
    }

    func testNoSessionThrows() {
        XCTAssertThrowsError(
            try sendIPCRequest(["help"], socketPath: tempSocket())
        )
    }

    func testStaleSocketFileDoesNotBlockStart() throws {
        let path = tempSocket()
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let server = IPCServer(socketPath: path) { _ in
            IPCResponse(ok: true, output: "ok")
        }
        try server.start()
        defer {
            server.stop()
        }
        let response = try sendIPCRequest([], socketPath: path)
        XCTAssertEqual(response.output, "ok")
    }

    func testStatusQueryJSON() throws {
        var session = CommandSession()
        var seed = session.manager.currentWorkspace()
        seed.columns = [Column(id: ColumnID(9), width: 100, windows: [WindowID(pid: 7, elementID: 9)])]
        session.manager.update(seed)
        XCTAssertTrue(session.manager.switchTo(2))
        let empty = try JSONSerialization.jsonObject(
            with: queryStatus(session: session).data(using: .utf8)!
        ) as! [String: Any]
        XCTAssertEqual(empty["workspace"] as! Int, 2)
        XCTAssertEqual(empty["columns"] as! Int, 0)
        XCTAssertTrue(empty["focusedWindow"] is NSNull)

        var first = session.manager.currentWorkspace()
        let id = WindowID(pid: 7, elementID: 3)
        first.columns = [Column(id: ColumnID(1), width: 300, windows: [id])]
        first.focusedWindow = id
        session.manager.update(first)
        let filled = try JSONSerialization.jsonObject(
            with: queryStatus(session: session).data(using: .utf8)!
        ) as! [String: Any]
        XCTAssertEqual(filled["columns"] as! Int, 1)
        XCTAssertEqual(filled["focusedWindow"] as! String, "7:3")
        XCTAssertEqual(filled["windows"] as! Int, 1)
        // NF-02: every display's stack is reported (index, counts, active).
        let stacks = filled["stacks"] as! [[String: Any]]
        XCTAssertEqual(stacks.count, 1)
        XCTAssertEqual(stacks[0]["focused"] as! Bool, true)
        XCTAssertEqual(stacks[0]["active"] as! Int, 2)
        let entries = stacks[0]["workspaces"] as! [[String: Any]]
        XCTAssertEqual(entries.map { $0["index"] as! Int }, [1, 2, 3])
        XCTAssertEqual(entries.map { $0["windows"] as! Int }, [1, 1, 0])
        XCTAssertEqual(entries.map { $0["active"] as! Bool }, [false, true, false])
    }

    func testDispatchStatusAndUnknown() {
        var session = CommandSession()
        let status = dispatchIPC(["status"], session: &session)
        XCTAssertTrue(status.ok)
        XCTAssertTrue(status.output!.contains("\"workspace\""))
        let unknown = dispatchIPC(["frobnicate"], session: &session)
        XCTAssertFalse(unknown.ok)
        XCTAssertNotNil(unknown.error)
        let help = dispatchIPC(["help"], session: &session)
        XCTAssertTrue(help.ok)
    }

    /// PF-Y: the accept loop retried every failure at once, so a lasting one
    /// (out of file descriptors) would spin a thread at 100 % CPU for the
    /// rest of the session. Only an interrupted or aborted connection is
    /// retried at once; any other failure waits.
    func testAcceptFailuresBackOffUnlessTransient() {
        XCTAssertEqual(ipcAcceptRetryDelay(errno: EINTR), 0)
        XCTAssertEqual(ipcAcceptRetryDelay(errno: ECONNABORTED), 0)
        for code in [EMFILE, ENFILE, ENOBUFS, ENOMEM, EINVAL] {
            XCTAssertGreaterThanOrEqual(ipcAcceptRetryDelay(errno: code), 0.1, "errno \(code)")
        }
    }

    /// A bound, listening socket that never accepts: connections complete in
    /// the kernel backlog, requests are buffered and never answered.
    private func listenSilently(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.socketFailed(errno)
        }
        var address = ipcSocketAddress(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw IPCError.bindFailed(errno)
        }
        return fd
    }

    /// PA-17b: a session that takes the connection but never answers made
    /// the client wait forever; it now fails with a timeout within the bound.
    func testClientTimesOutWhenTheSessionNeverAnswers() throws {
        let path = tempSocket()
        let listener = try listenSilently(path)
        defer {
            close(listener)
            unlink(path)
        }
        let started = Date()
        XCTAssertThrowsError(try sendIPCRequest(["status"], socketPath: path, timeout: 0.3)) { error in
            XCTAssertEqual(error as? IPCError, .timedOut)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.25)
        XCTAssertLessThan(elapsed, 3)
    }

    /// PA-17b: the default client bound outlasts `gio update`, which the app
    /// answers after up to 45 s (`UpdateController.answerCLI`).
    func testDefaultClientTimeoutCoversUpdateAnswers() {
        XCTAssertGreaterThan(ipcClientTimeout, 45)
    }

    /// PA-17b: the sequential server waited forever on a client that
    /// connected and sent nothing, so nobody else was served. The request
    /// read is bounded: the silent client gets an error envelope and the
    /// next client its answer.
    func testServerDropsASilentClientAndServesTheNext() throws {
        let path = tempSocket()
        let server = IPCServer(socketPath: path, timeout: 0.2) { _ in
            IPCResponse(ok: true, output: "ok")
        }
        try server.start()
        defer {
            server.stop()
        }
        let silent = try openRaw(path)
        defer {
            close(silent)
        }
        let response = try sendIPCRequest(["status"], socketPath: path, timeout: 5)
        XCTAssertEqual(response.output, "ok")
        let envelope = try JSONDecoder().decode(IPCResponse.self, from: ipcReceiveMessage(silent))
        XCTAssertEqual(envelope, IPCResponse(ok: false, error: "unreadable request"))
    }

    /// PA-17b: a client that timed out and closed before the reply must not
    /// take the session down: the reply write fails (no SIGPIPE) and the
    /// server keeps serving.
    func testServerSurvivesAClientThatGaveUp() throws {
        let path = tempSocket()
        let server = IPCServer(socketPath: path) { argv in
            if argv == ["slow"] {
                Thread.sleep(forTimeInterval: 0.4)
            }
            return IPCResponse(ok: true, output: argv.joined(separator: " "))
        }
        try server.start()
        defer {
            server.stop()
        }
        XCTAssertThrowsError(try sendIPCRequest(["slow"], socketPath: path, timeout: 0.1)) { error in
            XCTAssertEqual(error as? IPCError, .timedOut)
        }
        let response = try sendIPCRequest(["fast"], socketPath: path, timeout: 5)
        XCTAssertEqual(response.output, "fast")
    }
}
