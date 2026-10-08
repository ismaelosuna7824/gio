import CoreGraphics
import Foundation
import GioCore
@testable import GioSession

/// Test double: every read is a settable value; counts window-server queries.
final class StubSystemProbe: SystemProbe, @unchecked Sendable {
    var pressedMouseButtons = 0
    var mouseLocation = CGPoint.zero
    var frontmostPID: pid_t?
    var primaryScreenFrame: CGRect? = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    var primaryScreenVisibleFrame: CGRect? = CGRect(x: 0, y: 0, width: 1800, height: 1130)
    var regularPIDs: Set<pid_t> = []
    var names: [pid_t: String] = [:]
    var serverWindows: [ServerWindow] = []
    private(set) var serverQueries = 0

    func runningRegularPIDs() -> Set<pid_t> {
        regularPIDs
    }

    func isRunning(_ pid: pid_t) -> Bool {
        regularPIDs.contains(pid) || names[pid] != nil
    }

    func isRegularApplication(_ pid: pid_t) -> Bool {
        regularPIDs.contains(pid)
    }

    func applicationName(_ pid: pid_t) -> String? {
        names[pid]
    }

    func windowServerWindows(displayHeight: CGFloat) -> [ServerWindow] {
        serverQueries += 1
        return serverWindows
    }
}
