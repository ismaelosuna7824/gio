import XCTest
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
