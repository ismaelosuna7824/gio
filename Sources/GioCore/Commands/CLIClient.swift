import Foundation

/// SB-01: the app binary acts as the `gio` CLI when it is started under
/// that name (the `~/.local/bin/gio` link Install Command Line Tool makes).
/// Case-sensitive: the app's own executable is `Gio`.
public func isGioCLIInvocation(_ arguments: [String]) -> Bool {
    guard let first = arguments.first else {
        return false
    }
    return URL(fileURLWithPath: first).lastPathComponent == "gio"
}

/// `gio`: thin IPC client, shared by the SwiftPM `GioCLI` executable and the
/// app binary in CLI mode. Everything (including parsing) happens
/// server-side so scripts and humans share one source of truth. Returns the
/// exit status: 0 on success, 1 on a failed request or no session, 2 for
/// usage without arguments.
public func runGioCLI(
    arguments: [String], socketPath: String = defaultSocketPath(),
    output: (String) -> Void = { print($0) },
    error: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
) -> Int32 {
    guard !arguments.isEmpty else {
        output(cliUsage())
        return 2
    }
    do {
        let response = try sendIPCRequest(arguments, socketPath: socketPath)
        guard response.ok else {
            error(response.error ?? "request failed")
            return 1
        }
        if let text = response.output {
            output(text)
        }
        return 0
    } catch IPCError.timedOut {
        error("the Gio session did not answer within \(Int(ipcClientTimeout)) s")
        return 1
    } catch let failure {
        error("no running Gio session (start the app): \(failure)")
        return 1
    }
}
