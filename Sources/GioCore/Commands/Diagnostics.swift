import Foundation

public enum DiagnosticStatus: Equatable, Sendable {
    case ok, warning, failure
}

public struct DiagnosticRow: Equatable, Identifiable, Sendable {
    public let title: String
    public let value: String
    public let status: DiagnosticStatus
    public var id: String { title }
}

/// Doctor facts for the Diagnostics panel, built from the same session
/// facts the Overview uses. Unlike `runDoctor` this has no side effects
/// (it never writes a config template) and needs no IPC round trip: the
/// app is the session.
public func makeDiagnostics(
    facts: SessionFacts, version: String, build: String?,
    socketPath: String, socketExists: Bool, logPath: String
) -> [DiagnosticRow] {
    let config: DiagnosticRow
    if !facts.configExists {
        config = DiagnosticRow(
            title: "Config", value: "\(facts.configPath) (not created yet, defaults in use)", status: .ok
        )
    } else if facts.configMessages.isEmpty {
        config = DiagnosticRow(title: "Config", value: "\(facts.configPath) (valid)", status: .ok)
    } else {
        let count = facts.configMessages.count
        config = DiagnosticRow(
            title: "Config",
            value: "\(facts.configPath) (\(count) message\(count == 1 ? "" : "s"))",
            status: .warning
        )
    }
    return [
        DiagnosticRow(
            title: "Version", value: build.map { "\(version) (build \($0))" } ?? version, status: .ok
        ),
        DiagnosticRow(title: "Session", value: "Running", status: .ok),
        DiagnosticRow(
            title: "Accessibility",
            value: facts.accessibilityGranted ? "Granted" : "Missing",
            status: facts.accessibilityGranted ? .ok : .failure
        ),
        config,
        DiagnosticRow(
            title: "IPC socket",
            value: socketExists ? socketPath : "\(socketPath) (missing; the gio CLI cannot connect)",
            status: socketExists ? .ok : .failure
        ),
        DiagnosticRow(title: "Displays", value: "\(facts.displays.count)", status: .ok),
        DiagnosticRow(title: "Log file", value: logPath, status: .ok),
    ]
}
