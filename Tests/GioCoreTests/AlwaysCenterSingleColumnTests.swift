import XCTest
@testable import GioCore

/// NC-13: niri `always-center-single-column`: a workspace with a single
/// column shows it in the middle of the viewport instead of at the left
/// padding, whatever `center-focused-column` says.
final class AlwaysCenterSingleColumnTests: XCTestCase {
    private let viewport = CGRect(x: 100, y: 0, width: 1000, height: 800)

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func workspace(_ columns: [[UInt64]], width: CGFloat = 300) -> Workspace {
        Workspace(id: WorkspaceID(1), columns: columns.enumerated().map { index, ids in
            Column(id: ColumnID(UInt64(index + 1)), width: width, windows: ids.map(id), focusedWindowIndex: 0)
        })
    }

    private func engine(center: Bool) -> ScrollableLayoutEngine {
        ScrollableLayoutEngine(config: LayoutConfig(maximizeSingleWindow: false, alwaysCenterSingleColumn: center))
    }

    func testASingleColumnSitsInTheMiddle() throws {
        let result = try engine(center: true).calculate(workspace: workspace([[1, 2]]), viewport: viewport)
        XCTAssertEqual(try XCTUnwrap(result.frames[id(1)]).minX, 100 + 350, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.frames[id(2)]).minX, 100 + 350, accuracy: 0.001, "the whole column")
        XCTAssertEqual(result.viewportOffset, 0)
    }

    func testTwoColumnsAndTheOptionOffStayAtThePadding() throws {
        let two = try engine(center: true).calculate(workspace: workspace([[1], [2]]), viewport: viewport)
        XCTAssertEqual(try XCTUnwrap(two.frames[id(1)]).minX, 108, accuracy: 0.001)
        let off = try engine(center: false).calculate(workspace: workspace([[1]]), viewport: viewport)
        XCTAssertEqual(try XCTUnwrap(off.frames[id(1)]).minX, 108, accuracy: 0.001)
    }

    func testAColumnWiderThanTheStripKeepsThePadding() throws {
        let wide = try engine(center: true).calculate(workspace: workspace([[1]], width: 990), viewport: viewport)
        XCTAssertEqual(try XCTUnwrap(wide.frames[id(1)]).minX, 108, accuracy: 0.001)
    }

    func testTheRevealLeavesTheCenteredColumnAlone() throws {
        var single = workspace([[1]])
        single.focusedWindow = id(1)
        let planned = try planDisplayLayout(
            workspace: single, modes: [:], engine: engine(center: true), viewport: viewport, display: viewport,
            otherDisplays: [], centering: CenterRequest(mode: .always, previouslyFocused: nil)
        )
        XCTAssertEqual(try XCTUnwrap(planned.layout.frames[id(1)]).midX, viewport.midX, accuracy: 0.001)
    }

    func testConfigKeyIsOffByDefaultAndReachesTheEngine() throws {
        XCTAssertFalse(GioConfig().layout.alwaysCenterSingleColumn)
        XCTAssertFalse(GioConfig().makeLayoutConfig().alwaysCenterSingleColumn)
        let (on, warnings) = try parseGioConfig("[layout]\nalways-center-single-column = true\n").get()
        XCTAssertTrue(on.layout.alwaysCenterSingleColumn)
        XCTAssertTrue(on.makeLayoutConfig().alwaysCenterSingleColumn)
        XCTAssertTrue(warnings.isEmpty)
        guard case .failure = parseGioConfig("[layout]\nalways-center-single-column = 1\n") else {
            return XCTFail("a non-boolean must be rejected")
        }
    }

    func testTheLayoutFormTurnsItOnInTheFile() throws {
        var form = LayoutSettingsForm(config: LayoutSectionConfig())
        XCTAssertFalse(form.alwaysCenterSingleColumn)
        form.alwaysCenterSingleColumn = true
        guard case .success(let patched) = patchGioConfig("", edits: form.edits) else {
            return XCTFail("the edits must patch")
        }
        XCTAssertTrue(patched.config.layout.alwaysCenterSingleColumn)
    }
}
