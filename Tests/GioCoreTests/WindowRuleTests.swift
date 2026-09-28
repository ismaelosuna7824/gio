import XCTest
@testable import GioCore

/// Plan §18: exact matching, first-match-wins, placement pipeline.
final class WindowRuleTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func window(_ element: UInt64, app: String = "Code") -> ManagedWindow {
        ManagedWindow(
            id: id(element),
            pid: 10,
            application: app,
            title: "editor",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            mode: .tiled
        )
    }

    private func setup() -> (WindowRegistry, WorkspaceManager) {
        (WindowRegistry(), WorkspaceManager())
    }

    func testFirstMatchWinsEntirely() {
        let rules = [
            WindowRule(app: "Code", mode: .floating, workspace: 2),
            WindowRule(app: "Code", mode: .tiled, workspace: 5),
        ]
        XCTAssertEqual(
            evaluateRules(rules, app: "Code"),
            RuleOutcome(mode: .floating, workspace: 2)
        )
    }

    func testNoMatchMeansNoOpinion() {
        let rules = [WindowRule(app: "Code", mode: .floating)]
        XCTAssertEqual(evaluateRules(rules, app: "Safari"), .none)
        XCTAssertEqual(evaluateRules([], app: "Code"), .none)
    }

    func testMatchingIsExact() {
        let rules = [WindowRule(app: "Code", mode: .floating)]
        XCTAssertEqual(evaluateRules(rules, app: "code"), .none)
        XCTAssertEqual(evaluateRules(rules, app: "Code Helper"), .none)
    }

    func testPlaceWindowDefaultsToTiledCurrent() throws {
        let parts = setup()
        let registry = parts.0
        var manager = parts.1
        let placement = try placeWindow(window(1), rules: [], appKey: "Code", registry: registry, manager: &manager)
        XCTAssertEqual(placement, WindowPlacement(workspace: 1, column: 0))
        XCTAssertEqual(registry.find(id(1))!.mode, .tiled)
        let current = manager.currentWorkspace()
        XCTAssertEqual(current.columns.count, 1)
        XCTAssertEqual(current.focusedWindow, id(1))
    }

    func testPlaceWindowHonorsModeAndWorkspace() throws {
        let parts = setup()
        let registry = parts.0
        var manager = parts.1
        let rules = [WindowRule(app: "Calc", mode: .floating, workspace: 3)]
        let calc = ManagedWindow(
            id: id(7), pid: 11, application: "Calc", title: "",
            frame: CGRect(x: 0, y: 0, width: 300, height: 300), mode: .tiled
        )
        let placement = try placeWindow(calc, rules: rules, appKey: "Calc", registry: registry, manager: &manager)
        XCTAssertEqual(placement, WindowPlacement(workspace: 3, column: 0))
        XCTAssertEqual(registry.find(id(7))!.mode, .floating)
        XCTAssertEqual(manager.workspace(3)!.focusedWindow, id(7))
        XCTAssertEqual(manager.current, 1)
        XCTAssertTrue(manager.workspace(1)!.columns.isEmpty)
    }

    func testPlaceWindowIgnoresInvalidWorkspace() throws {
        let parts = setup()
        let registry = parts.0
        var manager = parts.1
        let rules = [WindowRule(app: "Code", workspace: 42)]
        let placement = try placeWindow(window(1), rules: rules, appKey: "Code", registry: registry, manager: &manager)
        XCTAssertEqual(placement.workspace, 1)
    }

    func testPlaceWindowDuplicateThrows() throws {
        let parts = setup()
        let registry = parts.0
        var manager = parts.1
        try placeWindow(window(1), rules: [], appKey: "Code", registry: registry, manager: &manager)
        XCTAssertThrowsError(
            try placeWindow(window(1), rules: [], appKey: "Code", registry: registry, manager: &manager)
        )
    }
}
