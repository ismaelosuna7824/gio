import CoreGraphics
import GioCore
import XCTest
@testable import GioUI

/// MM-04: moving the focused window to another display is discoverable: the
/// menu bar's Move to Display submenu and the launcher's
/// `> move-window-to-display N` (the same IPC verb).
final class MoveToDisplayMenuTests: XCTestCase {
    private let builtIn = MenuDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), name: "Built-in Retina Display")
    private let external = MenuDisplay(id: 3, frame: CGRect(x: -2160, y: -224, width: 2160, height: 1440), name: "LG HDR 4K")

    func testItemsListDisplaysByNumberAndNameAndMarkTheCurrentOne() {
        let items = moveToDisplayItems(displays: [external, builtIn], current: 1, hasFocusedWindow: true)
        XCTAssertEqual(items.map(\.title), ["1  Built-in Retina Display", "2  LG HDR 4K"])
        XCTAssertEqual(items.map(\.number), [1, 2])
        XCTAssertEqual(items.map(\.isCurrent), [true, false])
        XCTAssertEqual(items.map(\.isEnabled), [false, true], "the window's own display is not a target")
        XCTAssertEqual(items[1].argv, ["move-window-to-display", "2"])
    }

    func testNothingToMoveWithOneDisplayOrNoFocusedWindow() {
        XCTAssertEqual(moveToDisplayItems(displays: [builtIn], current: 1, hasFocusedWindow: true), [])
        XCTAssertTrue(
            moveToDisplayItems(displays: [external, builtIn], current: 1, hasFocusedWindow: false)
                .allSatisfy { !$0.isEnabled }
        )
    }

    func testTheLauncherRunsTheSameVerb() {
        XCTAssertEqual(
            routeLauncherInput("> move-window-to-display 2", apps: []),
            .runEntry(.gioCommand(argv: ["move-window-to-display", "2"], label: "move-window-to-display 2"))
        )
    }
}
