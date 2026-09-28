import ApplicationServices
import XCTest
@testable import GioCore
@testable import GioMacOS

/// RW-09 assembly: pure pieces unit tested (candidate filter, workspace
/// building, report rendering). `runTileReflow` itself needs live AX and is
/// validated by the user-operated `gio-poc tile` retest, never by mocks.
final class TileAssemblyTests: XCTestCase {
    private func discovered(
        pid: pid_t = 100,
        title: String? = "editor",
        minimized: Bool = false,
        focused: Bool = false
    ) -> DiscoveredSystemWindow {
        let app = AXUIElementCreateApplication(pid)
        return DiscoveredSystemWindow(
            window: SystemWindow(
                index: 0,
                pid: pid,
                appName: "Code",
                title: title,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                isFocused: focused,
                isMinimized: minimized,
                isFullscreen: false
            ),
            element: app,
            appElement: app
        )
    }

    private func managed(id: WindowID) -> ManagedWindow {
        ManagedWindow(
            id: id,
            pid: id.pid,
            application: "Code",
            title: "editor",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            mode: .tiled
        )
    }

    func testSelectTileCandidatesDropsMinimized() {
        let found = [
            discovered(minimized: false),
            discovered(minimized: true),
            discovered(minimized: true),
        ]
        let (candidates, skipped) = selectTileCandidates(found)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(skipped, 2)
    }

    func testMakeTileWorkspaceOneColumnPerWindow() {
        let ids = [WindowID(pid: 1, elementID: 1), WindowID(pid: 2, elementID: 2)]
        let workspace = makeTileWorkspace(windows: ids.map(managed))
        XCTAssertEqual(workspace.columns.count, 2)
        XCTAssertEqual(workspace.columns[0].windows, [ids[0]])
        XCTAssertEqual(workspace.columns[1].windows, [ids[1]])
        XCTAssertEqual(workspace.focusedColumn, 0)
        XCTAssertEqual(workspace.focusedWindow, ids[0])
        XCTAssertEqual(workspace.viewportOffset, 0)
    }

    func testMakeTileWorkspaceEmpty() {
        let workspace = makeTileWorkspace(windows: [])
        XCTAssertTrue(workspace.columns.isEmpty)
        XCTAssertNil(workspace.focusedWindow)
    }

    func testSplitVisibleFrames() {
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frames = [
            WindowID(pid: 1, elementID: 1): CGRect(x: 8, y: 8, width: 400, height: 784),
            WindowID(pid: 1, elementID: 2): CGRect(x: 900, y: 8, width: 400, height: 784),
            WindowID(pid: 1, elementID: 3): CGRect(x: 1200, y: 8, width: 400, height: 784),
        ]
        let (visible, skipped) = splitVisibleFrames(frames, in: viewport)
        XCTAssertEqual(Set(visible.keys), [WindowID(pid: 1, elementID: 1), WindowID(pid: 1, elementID: 2)])
        XCTAssertEqual(skipped, 1)
    }

    func testReportDescribesCounts() {
        let report = TileReflowReport(
            managed: [WindowID(pid: 1, elementID: 1)],
            skippedMinimized: 1,
            skippedUntileable: 2,
            skippedDiscovery: 0,
            reconcile: ReconcileReport(applied: [WindowID(pid: 1, elementID: 1)])
        )
        let text = report.describe()
        XCTAssertTrue(text.contains("managed=1"))
        XCTAssertTrue(text.contains("minimized=1"))
        XCTAssertTrue(text.contains("untileable=2"))
        XCTAssertTrue(text.contains("applied=1"))
    }
}
