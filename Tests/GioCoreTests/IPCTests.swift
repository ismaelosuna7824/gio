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
        XCTAssertTrue(session.manager.switchTo(2))
        let empty = try JSONSerialization.jsonObject(
            with: queryStatus(session: session).data(using: .utf8)!
        ) as! [String: Any]
        XCTAssertEqual(empty["workspace"] as! Int, 2)
        XCTAssertEqual(empty["columns"] as! Int, 0)
        XCTAssertTrue(empty["focusedWindow"] is NSNull)

        var first = session.manager.workspace(2)!
        let id = WindowID(pid: 7, elementID: 3)
        first.columns = [Column(id: ColumnID(1), width: 300, windows: [id])]
        first.focusedWindow = id
        session.manager.update(first)
        let filled = try JSONSerialization.jsonObject(
            with: queryStatus(session: session).data(using: .utf8)!
        ) as! [String: Any]
        XCTAssertEqual(filled["columns"] as! Int, 1)
        XCTAssertEqual(filled["focusedWindow"] as! String, "7:3")
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
}
