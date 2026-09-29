import XCTest
@testable import GioCore

/// WC-07: clicked focus is adopted without a re-layout storm; a rescan of
/// unchanged windows writes nothing; nothing moves under a pressed mouse.
final class FocusAdoptionTests: XCTestCase {
    private func id(_ element: UInt64, pid: pid_t) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    // MARK: Which window is focused

    func testOnlyTheFrontmostAppsFocusedWindowIsAdopted() {
        // Every running app reports one AXFocusedWindow; only the frontmost
        // app's is the user's focus.
        let candidates = [
            FocusCandidate(id: id(1, pid: 10), isFocused: true, isMinimized: false),
            FocusCandidate(id: id(2, pid: 20), isFocused: true, isMinimized: false),
            FocusCandidate(id: id(3, pid: 30), isFocused: true, isMinimized: false),
        ]
        XCTAssertEqual(adoptableFocus(among: candidates, frontmostPID: 10), id(1, pid: 10))
        XCTAssertEqual(adoptableFocus(among: candidates, frontmostPID: 20), id(2, pid: 20))
    }

    func testNoAdoptionWithoutFrontmostFocusedUnminimizedWindow() {
        let candidates = [
            FocusCandidate(id: id(1, pid: 10), isFocused: false, isMinimized: false),
            FocusCandidate(id: id(2, pid: 20), isFocused: true, isMinimized: true),
        ]
        XCTAssertNil(adoptableFocus(among: candidates, frontmostPID: 10))
        XCTAssertNil(adoptableFocus(among: candidates, frontmostPID: 20))
        XCTAssertNil(adoptableFocus(among: candidates, frontmostPID: nil))
        XCTAssertNil(adoptableFocus(among: candidates, frontmostPID: 99))
    }

    // MARK: Adopting into the workspace

    private func workspace(focus: Int = 0, offset: CGFloat = 0) -> Workspace {
        var columns: [Column] = []
        for index in 0..<6 {
            columns.append(Column(
                id: ColumnID(UInt64(index + 1)), width: 0,
                windows: [id(UInt64(index + 1), pid: 10 + pid_t(index))]
            ))
        }
        return Workspace(
            id: WorkspaceID(1), columns: columns, focusedColumn: focus,
            focusedWindow: columns[focus].windows[0], viewportOffset: offset
        )
    }

    func testAdoptingKnownWindowMovesColumnAndWindowFocus() throws {
        let adopted = try XCTUnwrap(adoptingFocus(id(4, pid: 13), in: workspace()))
        XCTAssertEqual(adopted.focusedColumn, 3)
        XCTAssertEqual(adopted.focusedWindow, id(4, pid: 13))
        XCTAssertEqual(adopted.columns[3].focusedWindowIndex, 0)
    }

    func testAdoptingUnknownWindowIsNil() {
        XCTAssertNil(adoptingFocus(id(99, pid: 99), in: workspace()))
    }

    func testAdoptingAlreadyFocusedWindowChangesNothing() {
        let current = workspace(focus: 2)
        XCTAssertEqual(adoptingFocus(id(3, pid: 12), in: current), current)
    }

    func testAdoptingStackedWindowSelectsItInsideItsColumn() throws {
        var current = workspace()
        let a = id(1, pid: 10), b = id(50, pid: 10)
        current.columns[0].windows = [a, b]
        let adopted = try XCTUnwrap(adoptingFocus(b, in: current))
        XCTAssertEqual(adopted.columns[0].focusedWindowIndex, 1)
        XCTAssertEqual(adopted.focusedWindow, b)
    }

    // MARK: Rescan of unchanged windows writes nothing

    /// Lanes run concurrently (one per pid), so the fake guards its state.
    private final class GridActuator: WindowActuator, @unchecked Sendable {
        private let lock = NSLock()
        private var storedFrames: [WindowID: CGRect] = [:]
        private var storedWrites = 0
        var frames: [WindowID: CGRect] {
            get { lock.withLock { storedFrames } }
            set { lock.withLock { storedFrames = newValue } }
        }
        var writes: Int {
            get { lock.withLock { storedWrites } }
            set { lock.withLock { storedWrites = newValue } }
        }
        func frame(of id: WindowID) throws -> CGRect? { lock.withLock { storedFrames[id] } }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            lock.withLock {
                storedWrites += 1
                storedFrames[id] = frame
            }
        }
        func focus(id: WindowID) throws {}
    }

    private func makeActuator() -> GridActuator {
        let actuator = GridActuator()
        for index in 0..<6 {
            actuator.frames[id(UInt64(index + 1), pid: 10 + pid_t(index))] =
                CGRect(x: 50, y: 50, width: 640, height: 480)
        }
        return actuator
    }

    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    private let engine = ScrollableLayoutEngine(config: LayoutConfig(defaultColumnWidth: 880))

    private func settle(_ current: Workspace, on actuator: GridActuator) throws -> Workspace {
        let planned = try planDisplayLayout(
            workspace: current, modes: [:], engine: engine,
            viewport: display, display: display, otherDisplays: []
        )
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: planned.plan.visible, parked: planned.plan.parked,
            focused: nil, currentlyFocused: nil
        )
        XCTAssertTrue(report.failed.isEmpty)
        return planned.workspace
    }

    func testRescanOfUnchangedWindowsProducesZeroWrites() throws {
        let actuator = makeActuator()
        var current = workspace()
        current = try settle(current, on: actuator)
        XCTAssertGreaterThan(actuator.writes, 0)

        // A rescan: every app reports a focused window, the frontmost app
        // (the one already focused) decides; the layout is untouched.
        let candidates = (0..<6).map {
            FocusCandidate(id: id(UInt64($0 + 1), pid: 10 + pid_t($0)), isFocused: true, isMinimized: false)
        }
        let focusedID = try XCTUnwrap(adoptableFocus(among: candidates, frontmostPID: 10))
        current = adoptingFocus(focusedID, in: current) ?? current
        actuator.writes = 0
        current = try settle(current, on: actuator)
        XCTAssertEqual(actuator.writes, 0)
    }

    func testLastAppWinsFocusWouldRewriteEveryWindow() throws {
        // Documents the defect: adopting the LAST app's focused window
        // (arbitrary) scrolls the strip and rewrites windows.
        let actuator = makeActuator()
        var current = try settle(workspace(), on: actuator)
        current = adoptingFocus(id(6, pid: 15), in: current) ?? current
        actuator.writes = 0
        _ = try settle(current, on: actuator)
        XCTAssertGreaterThan(actuator.writes, 0)
    }

    // MARK: Reveal only when needed

    func testFocusOnFullyVisibleColumnNeedsNoReflow() throws {
        let current = try planDisplayLayout(
            workspace: workspace(), modes: [:], engine: engine,
            viewport: display, display: display, otherDisplays: []
        ).workspace
        let adopted = try XCTUnwrap(adoptingFocus(id(2, pid: 11), in: current))
        let planned = try planDisplayLayout(
            workspace: adopted, modes: [:], engine: engine,
            viewport: display, display: display, otherDisplays: []
        )
        XCTAssertEqual(planned.workspace.viewportOffset, current.viewportOffset)
    }

    func testFocusOnOffViewportColumnRevealsIt() throws {
        let current = try planDisplayLayout(
            workspace: workspace(), modes: [:], engine: engine,
            viewport: display, display: display, otherDisplays: []
        ).workspace
        let adopted = try XCTUnwrap(adoptingFocus(id(6, pid: 15), in: current))
        let planned = try planDisplayLayout(
            workspace: adopted, modes: [:], engine: engine,
            viewport: display, display: display, otherDisplays: []
        )
        XCTAssertGreaterThan(planned.workspace.viewportOffset, current.viewportOffset)
        XCTAssertNotNil(planned.plan.visible[id(6, pid: 15)])
    }

    // MARK: Mouse-down deferral

    func testReflowRunsAtOnceWhenNoButtonIsDown() {
        var gate = ReflowDeferral()
        XCTAssertEqual(gate.request(mouseDown: false), .apply)
    }

    func testReflowWaitsForReleaseAndCoalescesRequests() {
        var gate = ReflowDeferral()
        XCTAssertEqual(gate.request(mouseDown: true), .poll(after: ReflowDeferral.pollInterval))
        XCTAssertEqual(gate.request(mouseDown: true), .alreadyPolling)
        XCTAssertEqual(gate.request(mouseDown: true), .alreadyPolling)
        XCTAssertEqual(gate.poll(mouseDown: true), .poll(after: ReflowDeferral.pollInterval))
        XCTAssertEqual(gate.poll(mouseDown: false), .apply)
        // Polling ended: a later press starts a fresh wait.
        XCTAssertEqual(gate.request(mouseDown: true), .poll(after: ReflowDeferral.pollInterval))
    }

    func testPollIntervalIsFiftyMilliseconds() {
        XCTAssertEqual(ReflowDeferral.pollInterval, 0.05)
    }
}
