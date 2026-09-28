import XCTest
@testable import GioCore

/// Plan §30 integration chain, Core without GUI: created → rules →
/// registry → workspace → layout → reconciler, plus focus, switching and
/// recovery through the same world. The mock actuator stands in for AX.
final class TilingPipelineTests: XCTestCase {
    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private func discovered(
        _ element: UInt64, app: String, frame: CGRect, focused: Bool = false
    ) -> ManagedWindow {
        ManagedWindow(
            id: id(element), pid: 10, application: app, title: app,
            frame: frame, mode: .tiled
        )
    }

    private final class PipeActuator: WindowActuator {
        var frames: [WindowID: CGRect] = [:]
        func frame(of id: WindowID) throws -> CGRect? {
            frames[id]
        }

        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            frames[id] = frame
        }

        func focus(id: WindowID) throws {}
    }

    private let viewport = CGRect(x: 0, y: 0, width: 1800, height: 1130)
    private let rules = [WindowRule(app: "Calculator", mode: .floating)]

    private func world() throws -> (
        registry: WindowRegistry, manager: WorkspaceManager,
        engine: ScrollableLayoutEngine, actuator: PipeActuator,
        reconciler: WindowReconciler<PipeActuator>
    ) {
        let registry = WindowRegistry()
        var manager = WorkspaceManager()
        let engine = ScrollableLayoutEngine()
        let actuator = PipeActuator()
        let reconciler = WindowReconciler(actuator: actuator)
        let apps = [("Code", 1), ("Terminal", 2), ("Calculator", 3)]
        for (index, (app, element)) in apps.enumerated() {
            let window = discovered(
                UInt64(element), app: app,
                frame: CGRect(x: 1700 + index * 10, y: 500, width: 800, height: 600),
                focused: element == 1
            )
            try placeWindow(window, rules: rules, appKey: app, registry: registry, manager: &manager)
            actuator.frames[window.id] = window.frame
        }
        return (registry, manager, engine, actuator, reconciler)
    }

    private func tiledWorkspace(
        manager: WorkspaceManager, registry: WindowRegistry
    ) -> Workspace {
        let modes = Dictionary(
            uniqueKeysWithValues: registry.managedWindows().map { ($0.id, $0.mode) }
        )
        return tilingWorkspace(from: manager.workspace(1)!, modes: modes)
    }

    func testCreatedToReconciled() throws {
        let world = try world()
        // Calculator floated out by its rule; two columns tile.
        XCTAssertEqual(world.registry.find(id(3))!.mode, .floating)
        let layout = try world.engine.calculate(
            workspace: tiledWorkspace(manager: world.manager, registry: world.registry),
            viewport: viewport
        )
        XCTAssertEqual(layout.frames.count, 2)
        XCTAssertNil(layout.frames[id(3)])
        let report = world.reconciler.reconcile(
            frames: layout.frames, focused: id(1), currentlyFocused: nil
        )
        XCTAssertEqual(report.applied.count, 2)
        XCTAssertTrue(report.failed.isEmpty)
    }

    func testRefocusIsIdempotent() throws {
        let world = try world()
        let layout = try world.engine.calculate(
            workspace: tiledWorkspace(manager: world.manager, registry: world.registry),
            viewport: viewport
        )
        _ = world.reconciler.reconcile(
            frames: layout.frames, focused: id(1), currentlyFocused: nil
        )
        let again = world.reconciler.reconcile(
            frames: layout.frames, focused: id(1), currentlyFocused: id(1)
        )
        XCTAssertEqual(again.alreadyCorrect.count, 2)
        XCTAssertTrue(again.applied.isEmpty)
    }

    func testEmptyWorkspaceReconcilesToNothing() throws {
        var world = try world()
        XCTAssertTrue(world.manager.switchTo(2))
        let layout = try world.engine.calculate(
            workspace: world.manager.workspace(2)!, viewport: viewport
        )
        XCTAssertTrue(layout.frames.isEmpty)
        let report = world.reconciler.reconcile(
            frames: layout.frames, focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report, ReconcileReport())
    }

    func testClosedWindowLeavesNoReferences() throws {
        var world = try world()
        var state = RecoveryState(
            registry: world.registry, manager: world.manager, displays: DisplayManager()
        )
        let report = recover(
            state: &state,
            input: RecoveryInput(liveIDs: [id(1), id(3)])
        )
        // id(2) vanished from enumeration: pruned from registry and columns.
        XCTAssertEqual(report.prunedStale, [id(2)])
        XCTAssertNil(state.registry.find(id(2)))
        XCTAssertFalse(state.manager.workspace(1)!.columns.flatMap(\.windows).contains(id(2)))
        // Focus survived on the remaining window (last placed).
        XCTAssertEqual(state.manager.workspace(1)!.focusedWindow, id(3))
        world.manager = state.manager
        let layout = try world.engine.calculate(
            workspace: tiledWorkspace(manager: world.manager, registry: world.registry),
            viewport: viewport
        )
        XCTAssertEqual(layout.frames.count, 1)
    }
}
