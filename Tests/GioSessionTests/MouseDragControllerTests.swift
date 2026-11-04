import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

/// MD-01: the tap thread's gate takes exactly the modifier presses over a
/// frontmost tiled window (and their drags and release); the session side
/// writes the strip through the reconciler's sink while the button is
/// down, commits on release and abandons a click, a drop nowhere or a
/// workspace that changed meanwhile.
final class MouseDragControllerTests: XCTestCase {
    private final class Sink: MotionFrameSink {
        var writes: [WindowID: CGRect] = [:]

        func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool {
            for write in writes {
                self.writes[write.id] = write.to
            }
            return true
        }

        func takeMotionStats() -> [pid_t: MotionWriteStats] { [:] }
    }

    private final class World: @unchecked Sendable {
        var manager = WorkspaceManager()
        var physical: [WindowID: CGRect] = [:]
        var calls: [String] = []
        var settled: [Set<WindowID>] = []
        var abandons = 0
        var logs: [String] = []
        let sink = Sink()
    }

    private let display = DisplayID(1)
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let engine = ScrollableLayoutEngine(config: LayoutConfig(padding: 8, gap: 8))
    private var world: World!
    private var controller: MouseDragController!

    private func id(_ n: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: n)
    }

    /// Three 400 pt columns: screen x 8-408, 416-816, 824-1224.
    override func setUp() {
        world = World()
        world.manager.syncDisplays([display])
        var workspace = world.manager.currentWorkspace()
        workspace.columns = (1...3).map { Column(id: ColumnID(UInt64($0)), width: 400, windows: [id(UInt64($0))]) }
        workspace.focusedColumn = 0
        workspace.focusedWindow = id(1)
        world.manager.update(workspace)
        let world = world!
        controller = MouseDragController(context: .init(
            surface: { [unowned self] _ in surface() },
            physicalFrames: { world.physical },
            sink: { world.sink },
            updateManager: { body in body(&world.manager) },
            beginTracking: { world.calls.append("begin") },
            recordSampled: { id, frame, _ in world.physical[id] = frame },
            markUnverified: { _ in },
            focusedWindow: { world.manager.currentWorkspace().focusedWindow },
            publishFocusRing: {},
            settle: { windows, _ in world.settled.append(windows) },
            abandon: { world.abandons += 1 },
            log: { _, line in world.logs.append(line) },
            now: { 0 }
        ))
    }

    private func surface() -> GestureSurface {
        GestureSurface(
            display: display, workspace: world.manager.currentWorkspace(), modes: [:], engine: engine,
            viewport: viewport, displayFrame: viewport, otherDisplays: [], centering: false
        )
    }

    func testResizeFollowsThePointerThenCommitsOnRelease() {
        controller.deliver([.begin(.resize, id(1), CGPoint(x: 300, y: 400)), .move(CGPoint(x: 400, y: 400))])
        XCTAssertTrue(controller.isTracking)
        XCTAssertEqual(world.calls, ["begin"])
        XCTAssertEqual(world.sink.writes[id(1)]?.width ?? 0, 500, accuracy: 0.5)
        XCTAssertEqual(world.sink.writes[id(2)]?.minX ?? 0, 516, accuracy: 0.5, "the strip makes room live")
        XCTAssertEqual(world.manager.currentWorkspace().columns[0].widthSpec, .points(400), "State waits for the release")
        XCTAssertEqual(controller.animatingPids, [10])

        controller.deliver([.end(CGPoint(x: 400, y: 400))])
        XCTAssertFalse(controller.isTracking)
        XCTAssertEqual(world.settled.count, 1)
        let committed = world.manager.currentWorkspace()
        let laidOut = try? engine.calculate(workspace: committed, viewport: viewport).frames
        XCTAssertEqual(laidOut?[id(1)]?.width ?? 0, 500, accuracy: 0.5)
    }

    func testMoveDropsTheWindowIntoTheSlotAndFollowsThePointer() {
        // Window 1 grabbed at its center, dropped on window 3's center: swap.
        controller.deliver([.begin(.move, id(1), CGPoint(x: 208, y: 400)), .move(CGPoint(x: 1000, y: 400))])
        XCTAssertEqual(world.sink.writes[id(1)]?.minX ?? 0, 8 + 792, accuracy: 0.5, "the window follows the pointer")
        XCTAssertEqual(world.sink.writes[id(3)]?.minX ?? 0, 8, accuracy: 0.5, "window 3 takes the first slot")
        controller.deliver([.end(CGPoint(x: 1000, y: 400))])
        XCTAssertEqual(world.manager.currentWorkspace().columns.map(\.windows), [[id(3)], [id(2)], [id(1)]])
        XCTAssertEqual(world.settled.count, 1)
    }

    func testTheReleaseFocusesTheDraggedWindow() {
        var focused: [Bool] = []
        let world = world!
        controller = MouseDragController(context: .init(
            surface: { [unowned self] _ in surface() }, physicalFrames: { [:] }, sink: { world.sink },
            updateManager: { body in body(&world.manager) }, beginTracking: {}, recordSampled: { _, _, _ in },
            markUnverified: { _ in }, focusedWindow: { nil }, publishFocusRing: {},
            settle: { _, changed in focused.append(changed) }, abandon: {}, log: { _, _ in }
        ))
        controller.deliver([.begin(.resize, id(2), CGPoint(x: 700, y: 400)), .end(CGPoint(x: 760, y: 400))])
        XCTAssertEqual(focused, [true])
        XCTAssertEqual(world.manager.currentWorkspace().focusedWindow, id(2))
        XCTAssertEqual(world.manager.currentWorkspace().focusedColumn, 1)
    }

    func testAClickOrADropNowhereIsAbandoned() {
        controller.deliver([.begin(.move, id(1), CGPoint(x: 208, y: 400)), .end(CGPoint(x: 209, y: 400))])
        controller.deliver([.begin(.move, id(1), CGPoint(x: 208, y: 400)), .end(CGPoint(x: 412, y: 400))])
        XCTAssertEqual(world.abandons, 2)
        XCTAssertEqual(world.settled, [])
        XCTAssertEqual(world.manager.currentWorkspace().columns.map(\.windows), [[id(1)], [id(2)], [id(3)]])
        let before = world.manager.currentWorkspace()
        XCTAssertEqual(before.columns[0].widthSpec, .points(400))
    }

    func testAWorkspaceThatChangedMeanwhileIsNotOverwritten() {
        controller.deliver([.begin(.move, id(1), CGPoint(x: 208, y: 400)), .move(CGPoint(x: 1000, y: 400))])
        var changed = world.manager.currentWorkspace()
        changed.columns.append(Column(id: ColumnID(9), width: 400, windows: [id(9)]))
        world.manager.update(changed)
        controller.deliver([.end(CGPoint(x: 1000, y: 400))])
        XCTAssertEqual(world.abandons, 1)
        XCTAssertEqual(world.manager.currentWorkspace().columns.map(\.windows), [[id(1)], [id(2)], [id(3)], [id(9)]])
    }

    func testAFloatingWindowIsNotDragged() {
        let world = world!
        controller = MouseDragController(context: .init(
            surface: { [unowned self] _ in
                var floating = surface()
                floating.modes = [id(1): .floating]
                return floating
            },
            physicalFrames: { [:] }, sink: { world.sink }, updateManager: { body in body(&world.manager) },
            beginTracking: { world.calls.append("begin") }, recordSampled: { _, _, _ in }, markUnverified: { _ in },
            focusedWindow: { nil }, publishFocusRing: {}, settle: { windows, _ in world.settled.append(windows) },
            abandon: { world.abandons += 1 }, log: { _, _ in }
        ))
        controller.deliver([.begin(.resize, id(1), CGPoint(x: 300, y: 400)), .move(CGPoint(x: 400, y: 400))])
        XCTAssertFalse(controller.isTracking)
        XCTAssertEqual(world.calls, [])
        XCTAssertEqual(world.sink.writes, [:])
    }

    // MARK: - Gate

    private final class Received: @unchecked Sendable {
        let lock = NSLock()
        var signals: [MouseDragSignal] = []

        func append(_ batch: [MouseDragSignal]) {
            lock.lock()
            signals += batch
            lock.unlock()
        }
    }

    private func event(_ phase: MouseButtonPhase, _ button: MouseButton, x: CGFloat, modifiers: Set<HotkeyModifier> = [.alt]) -> MouseButtonEvent {
        MouseButtonEvent(phase: phase, button: button, location: CGPoint(x: x, y: 400), modifiers: modifiers)
    }

    func testTheGateTakesAModifierDragOverAFrontmostTileAndNothingElse() {
        let scheduler = ManualScheduler()
        let received = Received()
        let gate = MouseDragGate(scheduler: scheduler, ownPID: 99, topWindowPID: { $0.x < 500 ? 10 : 20 }) {
            received.append($0)
        }
        gate.configure(MouseDragSettings())
        gate.publish([id(1): CGRect(x: 8, y: 8, width: 400, height: 784), WindowID(pid: 30, elementID: 1): CGRect(x: 600, y: 8, width: 300, height: 784)])

        XCTAssertFalse(gate.handle(event(.down, .left, x: 100, modifiers: [])), "a plain click reaches the app")
        XCTAssertFalse(gate.handle(event(.down, .left, x: 450)), "off every tile")
        XCTAssertFalse(gate.handle(event(.down, .left, x: 700)), "another app's window covers the tile")
        XCTAssertFalse(gate.handle(event(.dragged, .left, x: 120)), "no drag taken")

        XCTAssertTrue(gate.handle(event(.down, .right, x: 100)))
        XCTAssertFalse(gate.handle(event(.down, .left, x: 100)), "one drag at a time")
        XCTAssertTrue(gate.handle(event(.dragged, .right, x: 120)))
        XCTAssertTrue(gate.handle(event(.dragged, .right, x: 140)))
        XCTAssertEqual(received.signals, [], "the session queue drains later")
        scheduler.runPending()
        XCTAssertEqual(received.signals, [.begin(.resize, id(1), CGPoint(x: 100, y: 400)), .move(CGPoint(x: 140, y: 400))])
        XCTAssertTrue(gate.handle(event(.up, .right, x: 150, modifiers: [])), "the release goes with its drag")
        XCTAssertFalse(gate.handle(event(.up, .right, x: 150)))
        scheduler.runPending()
        XCTAssertEqual(received.signals.last, .end(CGPoint(x: 150, y: 400)))
    }

    func testTheGateTakesNothingWhileTheDragsAreOff() {
        let gate = MouseDragGate(scheduler: ManualScheduler(), ownPID: 99, topWindowPID: { _ in 10 }) { _ in }
        gate.publish([id(1): CGRect(x: 8, y: 8, width: 400, height: 784)])
        XCTAssertFalse(gate.handle(event(.down, .left, x: 100)), "before the config arrives")
        gate.configure(MouseDragSettings(move: false, resize: true, modifiers: [.alt]))
        XCTAssertFalse(gate.handle(event(.down, .left, x: 100)))
        XCTAssertTrue(gate.handle(event(.down, .right, x: 100)))
    }
}
