import XCTest
@testable import GioCore

final class WorkspaceModelTests: XCTestCase {
    func testEmptyAndRepeatedSwitches() throws {
        var model = WorkspaceModel()
        try model.addDisplay("left", initialWorkspace: "one")
        try model.addWorkspace("two", on: "left")
        XCTAssertEqual(try model.switchTo("two", on: "left"), [])
        XCTAssertEqual(try model.switchTo("two", on: "left"), [])
        XCTAssertEqual(try model.activeWorkspace(on: "left"), "two")
    }

    func testDeterministicTransitionsAndIndependentDisplays() throws {
        var model = WorkspaceModel()
        try model.addDisplay("left", initialWorkspace: "one")
        try model.addWorkspace("two", on: "left")
        try model.addDisplay("right", initialWorkspace: "one")
        try model.addWorkspace("two", on: "right")
        XCTAssertEqual(try model.assign("b", to: "one", on: "left"), [])
        XCTAssertEqual(try model.assign("a", to: "one", on: "left"), [])
        XCTAssertEqual(try model.assign("d", to: "two", on: "left"), [.hide("d")])
        XCTAssertEqual(try model.assign("c", to: "two", on: "left"), [.hide("c")])
        XCTAssertEqual(try model.assign("remote", to: "one", on: "right"), [])
        XCTAssertEqual(try model.switchTo("two", on: "left"), [
            .hide("a"), .hide("b"), .show("c"), .show("d")
        ])
        XCTAssertEqual(try model.activeWorkspace(on: "right"), "one")
        XCTAssertEqual(try model.switchTo("two", on: "right"), [.hide("remote")])
        XCTAssertEqual(try model.switchTo("one", on: "left"), [
            .hide("c"), .hide("d"), .show("a"), .show("b")
        ])
    }

    func testReassignmentChangesVisibilityOnlyWhenNecessary() throws {
        var model = WorkspaceModel()
        try model.addDisplay("a", initialWorkspace: "one")
        try model.addWorkspace("two", on: "a")
        try model.addDisplay("b", initialWorkspace: "one")
        XCTAssertEqual(try model.assign("w", to: "one", on: "a"), [])
        XCTAssertEqual(try model.reassign("w", to: "two", on: "a"), [.hide("w")])
        XCTAssertEqual(try model.reassign("w", to: "two", on: "a"), [])
        XCTAssertEqual(try model.reassign("w", to: "one", on: "b"), [.show("w")])
        XCTAssertEqual(try model.membership(of: "w").display, "b")
        XCTAssertEqual(try model.switchTo("two", on: "a"), [])
        XCTAssertEqual(try model.removeWindow("w"), [])
        XCTAssertThrowsError(try model.membership(of: "w")) { error in
            XCTAssertEqual(error as? WorkspaceModelError, .unknownWindow("w"))
        }
    }

    func testDisplayRemovalShowsHiddenWindowsAndClearsMembership() throws {
        var model = WorkspaceModel()
        try model.addDisplay("a", initialWorkspace: "one")
        try model.addWorkspace("two", on: "a")
        try model.addDisplay("b", initialWorkspace: "one")
        try model.assign("visible", to: "one", on: "a")
        try model.assign("z", to: "two", on: "a")
        try model.assign("x", to: "two", on: "a")
        try model.assign("other", to: "one", on: "b")
        XCTAssertEqual(try model.removeDisplay("a"), [.show("x"), .show("z")])
        XCTAssertThrowsError(try model.membership(of: "visible"))
        XCTAssertThrowsError(try model.membership(of: "x"))
        XCTAssertEqual(try model.membership(of: "other").display, "b")
        try model.addDisplay("a", initialWorkspace: "new")
        XCTAssertEqual(try model.assign("x", to: "new", on: "a"), [])
    }

    func testInvalidRequestsDoNotMutateState() throws {
        var model = WorkspaceModel()
        try model.addDisplay("a", initialWorkspace: "one")
        try model.assign("w", to: "one", on: "a")
        XCTAssertThrowsError(try model.addDisplay("a", initialWorkspace: "other")) {
            XCTAssertEqual($0 as? WorkspaceModelError, .duplicateDisplay("a"))
        }
        XCTAssertThrowsError(try model.addWorkspace("one", on: "a")) {
            XCTAssertEqual($0 as? WorkspaceModelError, .duplicateWorkspace("a", "one"))
        }
        XCTAssertThrowsError(try model.switchTo("missing", on: "a")) {
            XCTAssertEqual($0 as? WorkspaceModelError, .unknownWorkspace("a", "missing"))
        }
        XCTAssertThrowsError(try model.assign("w", to: "one", on: "a")) {
            XCTAssertEqual($0 as? WorkspaceModelError, .duplicateWindow("w"))
        }
        XCTAssertThrowsError(try model.reassign("w", to: "one", on: "missing")) {
            XCTAssertEqual($0 as? WorkspaceModelError, .unknownDisplay("missing"))
        }
        XCTAssertThrowsError(try model.removeDisplay("missing"))
        XCTAssertEqual(try model.membership(of: "w").workspace, "one")
        XCTAssertEqual(try model.activeWorkspace(on: "a"), "one")
    }
}
