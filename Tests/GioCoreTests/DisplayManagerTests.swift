import XCTest
@testable import GioCore

/// Plan §16: independent per-display state, topology transitions, and the
/// canonical case — unplugging B never corrupts A.
final class DisplayManagerTests: XCTestCase {
    private let main = DisplayID(1)
    private let external = DisplayID(2)
    private let frameA = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let frameB = CGRect(x: 1800, y: 0, width: 2560, height: 1440)

    func testConnectStartsFresh() {
        var manager = DisplayManager()
        let state = manager.connect(main, frame: frameA, workspace: WorkspaceID(1))
        XCTAssertEqual(state.frame, frameA)
        XCTAssertEqual(state.workspace, WorkspaceID(1))
        XCTAssertEqual(state.viewport, Viewport(offset: 0, width: 1800))
    }

    func testTwoDisplaysHoldIndependentState() {
        var manager = DisplayManager()
        manager.connect(main, frame: frameA, workspace: WorkspaceID(1))
        manager.connect(external, frame: frameB, workspace: WorkspaceID(2))
        manager.updateViewport(Viewport(offset: 500, width: 2560), for: external)
        XCTAssertEqual(manager.display(main)!.viewport.offset, 0)
        XCTAssertEqual(manager.display(external)!.viewport.offset, 500)
        XCTAssertEqual(manager.display(main)!.workspace, WorkspaceID(1))
        XCTAssertEqual(manager.display(external)!.workspace, WorkspaceID(2))
    }

    func testDisconnectingBKeepsAIntact() {
        var manager = DisplayManager()
        manager.connect(main, frame: frameA, workspace: WorkspaceID(1))
        manager.connect(external, frame: frameB, workspace: WorkspaceID(2))
        let removed = manager.disconnect(external)
        XCTAssertEqual(removed?.workspace, WorkspaceID(2))
        XCTAssertNil(manager.display(external))
        let survivor = manager.display(main)!
        XCTAssertEqual(survivor.frame, frameA)
        XCTAssertEqual(survivor.workspace, WorkspaceID(1))
        XCTAssertEqual(survivor.viewport.offset, 0)
    }

    func testReconnectRefreshesFrameKeepsOffsetAndFollowsTheSyncedWorkspace() {
        var manager = DisplayManager()
        manager.connect(main, frame: frameA, workspace: WorkspaceID(1))
        manager.updateViewport(Viewport(offset: 200, width: 1800), for: main)
        let scaled = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let refreshed = manager.connect(main, frame: scaled, workspace: WorkspaceID(9))
        XCTAssertEqual(refreshed.frame, scaled)
        XCTAssertEqual(refreshed.viewport.width, 1512)
        XCTAssertEqual(refreshed.viewport.offset, 200)
        // MM-04: the sync passes the manager's active workspace of the
        // display; a known display follows it (a hot-plug may have moved a
        // named workspace away from it).
        XCTAssertEqual(refreshed.workspace, WorkspaceID(9))
    }

    func testAssignMovesDisplayBetweenWorkspaces() {
        var manager = DisplayManager()
        manager.connect(main, frame: frameA, workspace: WorkspaceID(1))
        XCTAssertTrue(manager.assign(main, workspace: WorkspaceID(4)))
        XCTAssertEqual(manager.display(main)!.workspace, WorkspaceID(4))
        XCTAssertFalse(manager.assign(DisplayID(99), workspace: WorkspaceID(4)))
    }

    func testUnknownDisplayUpdatesAreNoOps() {
        var manager = DisplayManager()
        manager.updateViewport(Viewport(offset: 50, width: 800), for: DisplayID(99))
        XCTAssertNil(manager.display(DisplayID(99)))
        XCTAssertTrue(manager.allDisplays().isEmpty)
    }

    func testAllDisplaysSorted() {
        var manager = DisplayManager()
        manager.connect(external, frame: frameB, workspace: WorkspaceID(2))
        manager.connect(main, frame: frameA, workspace: WorkspaceID(1))
        XCTAssertEqual(manager.allDisplays().map(\.id), [main, external])
    }

    func testAllDisplaysFollowGeometryNotIDs() {
        // MM-01: left to right, then top to bottom; the raw ID is irrelevant.
        var manager = DisplayManager()
        manager.connect(DisplayID(1), frame: frameA, workspace: WorkspaceID(1))
        manager.connect(DisplayID(2), frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440), workspace: WorkspaceID(2))
        manager.connect(DisplayID(3), frame: CGRect(x: 0, y: 1169, width: 1800, height: 1000), workspace: WorkspaceID(3))
        XCTAssertEqual(manager.allDisplays().map(\.id), [DisplayID(2), DisplayID(3), DisplayID(1)])
    }
}
