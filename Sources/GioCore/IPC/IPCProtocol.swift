import Foundation

/// Plan §22 wire format. Requests carry raw CLI argv so the server parses
/// once (single source of truth); responses envelope human output or a
/// machine-readable JSON string (see `status`). Newline-safe via the
/// length-prefixed framing in IPCTransport — outputs are multi-line.
public struct IPCRequest: Codable, Equatable, Sendable {
    public var argv: [String]

    public init(argv: [String]) {
        self.argv = argv
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var output: String?
    public var error: String?

    public init(ok: Bool, output: String? = nil, error: String? = nil) {
        self.ok = ok
        self.output = output
        self.error = error
    }
}

public enum IPCError: Error, Equatable {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case connectFailed(Int32)
    case ioError
    /// PA-17b: the peer did not send or read within the socket timeout.
    case timedOut
    case messageTooLarge
    case decodeFailed
}

public func defaultSocketPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/gio.sock"
}
