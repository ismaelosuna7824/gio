import Foundation
import GioCore

/// `gio`: thin IPC client. Everything (including parsing) happens
/// server-side so scripts and humans share one source of truth.
func gioFail(_ message: String, code: Int32 = 1) -> Never {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(code)
}

let gioArguments = Array(CommandLine.arguments.dropFirst())
guard !gioArguments.isEmpty else {
    print(cliUsage())
    exit(2)
}

do {
    let response = try sendIPCRequest(gioArguments, socketPath: defaultSocketPath())
    if response.ok {
        if let output = response.output {
            print(output)
        }
    } else {
        gioFail(response.error ?? "request failed")
    }
} catch {
    gioFail("no running Gio session (start the daemon): \(error)")
}
