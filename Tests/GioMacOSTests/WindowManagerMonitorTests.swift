import XCTest
@testable import GioMacOS

/// WC-22: every running process shows up by name, other users' too (live
/// 2026-11-04: `proc_name` answered ESRCH for processes it may not inspect,
/// so a running `yabai` went unseen). WindowServer runs as `_windowserver`.
final class WindowManagerMonitorTests: XCTestCase {
    func testProcessesOfOtherUsersAreListedByName() {
        XCTAssertTrue(runningProcessNames().contains("WindowServer"))
    }
}
