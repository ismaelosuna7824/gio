import XCTest
import ApplicationServices
import GioCore
@testable import GioMacOS

final class SystemWindowTests: XCTestCase {
    func testDescribeFullWindow() {
        let window = SystemWindow(
            index: 3,
            pid: 1234,
            appName: "Code",
            title: "gio — editor",
            frame: CGRect(x: 10, y: 20, width: 800, height: 600),
            isFocused: true,
            isMinimized: false,
            isFullscreen: false
        )
        XCTAssertEqual(
            window.describe(),
            "3 pid=1234 app=Code title=gio — editor frame=(10,20,800,600) focused"
        )
    }

    func testDescribeUnknownsAndMinimized() {
        let window = SystemWindow(
            index: 0,
            pid: 42,
            appName: "unknown",
            title: nil,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isFocused: false,
            isMinimized: true,
            isFullscreen: nil
        )
        XCTAssertEqual(
            window.describe(),
            "0 pid=42 app=unknown title=<unknown> frame=(0,0,100,100) minimized fullscreen=<unknown>"
        )
    }

    func testDescribeFullscreenFlag() {
        let window = SystemWindow(
            index: 1,
            pid: 7,
            appName: "Safari",
            title: "",
            frame: CGRect(x: 0, y: 25, width: 1440, height: 875),
            isFocused: false,
            isMinimized: false,
            isFullscreen: true
        )
        XCTAssertTrue(window.describe().contains("fullscreen"))
        XCTAssertFalse(window.describe().contains("fullscreen=<unknown>"))
    }

    func testDescribeFrame() {
        XCTAssertEqual(describeFrame(CGRect(x: 8, y: 47, width: 440, height: 553)), "(8,47,440,553)")
    }
}

final class DiscoveryScopeTests: XCTestCase {
    func testOwnProcessIsNeverManaged() {
        XCTAssertFalse(isManageableProcess(pid: 42, ownPID: 42, onlyPID: nil))
        XCTAssertFalse(isManageableProcess(pid: 42, ownPID: 42, onlyPID: 42))
    }

    // Live crash 2026-09-29: Gio's own main window was adopted as focus,
    // registered and animated; AX writes to an in-process element run
    // AppKit off the main thread and crash. The actuator is the last gate.
    func testActuatorRefusesGiosOwnWindows() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let actuator = AXWindowActuator(displayHeight: 1000)
        let element = AXUIElementCreateApplication(ownPID)
        actuator.register(elementID: 1, pid: ownPID, element: element, appElement: element)
        XCTAssertNil(actuator.id(matching: element, pid: ownPID))
        XCTAssertNil(actuator.element(for: WindowID(pid: ownPID, elementID: 1)))
    }

    // PF-K: `AXEnhancedUserInterface` is never read or written on Gio's own
    // app element (in-process AX runs AppKit on the lane thread).
    func testEnhancedUserInterfaceSwitchRefusesGiosOwnPid() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let control = AXEnhancedUserInterfaceSwitch()
        XCTAssertNil(control.enhancedUserInterface(pid: ownPID))
        XCTAssertFalse(control.setEnhancedUserInterface(false, pid: ownPID))
        XCTAssertFalse(control.setEnhancedUserInterface(true, pid: 0))
    }

    func testActuatorStillRegistersOtherProcesses() {
        let other: pid_t = ProcessInfo.processInfo.processIdentifier &+ 1
        let actuator = AXWindowActuator(displayHeight: 1000)
        let element = AXUIElementCreateApplication(other)
        actuator.register(elementID: 1, pid: other, element: element, appElement: element)
        XCTAssertEqual(actuator.id(matching: element, pid: other), WindowID(pid: other, elementID: 1))
    }

    func testOtherProcessesFollowOnlyPID() {
        XCTAssertTrue(isManageableProcess(pid: 7, ownPID: 42, onlyPID: nil))
        XCTAssertTrue(isManageableProcess(pid: 7, ownPID: 42, onlyPID: 7))
        XCTAssertFalse(isManageableProcess(pid: 7, ownPID: 42, onlyPID: 8))
    }

    func testBundleIDIsCarriedAndOptional() {
        let plain = SystemWindow(
            index: 0, pid: 1, appName: "A", title: nil, frame: .zero,
            isFocused: false, isMinimized: false, isFullscreen: nil
        )
        XCTAssertNil(plain.bundleID)
        let tagged = SystemWindow(
            index: 0, pid: 1, appName: "A", title: nil, frame: .zero,
            isFocused: false, isMinimized: false, isFullscreen: nil, bundleID: "com.a"
        )
        XCTAssertEqual(tagged.bundleID, "com.a")
        XCTAssertFalse(tagged.describe().contains("com.a"), "describe stays as it was")
    }
}
