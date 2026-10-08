import XCTest
@testable import GioCore

/// SW-01: a workspace whose only tiled window is alone fills the strip, as
/// `maximize-column` would; a second window brings the stored widths back.
final class MaximizeSingleWindowTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let engine = ScrollableLayoutEngine(config: LayoutConfig(maximizeSingleWindow: true))

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func workspace(_ columns: [[UInt64]], width: CGFloat = 300) -> Workspace {
        Workspace(id: WorkspaceID(1), columns: columns.enumerated().map { index, ids in
            Column(id: ColumnID(UInt64(index + 1)), width: width, windows: ids.map(id), focusedWindowIndex: 0)
        })
    }

    func testALoneWindowFillsTheStripLikeMaximizeColumn() throws {
        let result = try engine.calculate(workspace: workspace([[1]]), viewport: viewport)
        // Proportion 1: 1000 - 2 * 8 padding.
        XCTAssertEqual(result.frames, [id(1): CGRect(x: 8, y: 8, width: 984, height: 784)])
        XCTAssertEqual(result.contentWidth, 1000)
        let maximized = toggleMaximizeFocusedColumn(in: workspace([[1]]))
        let manual = try ScrollableLayoutEngine().calculate(workspace: maximized, viewport: viewport)
        XCTAssertEqual(result.frames, manual.frames, "same frame as Alt+F")
    }

    func testMoreThanOneWindowKeepsTheStoredWidths() throws {
        let columns = try engine.calculate(workspace: workspace([[1], [2]]), viewport: viewport)
        XCTAssertEqual(columns.frames[id(1)]?.width, 300)
        XCTAssertEqual(columns.frames[id(2)]?.width, 300)
        let stacked = try engine.calculate(workspace: workspace([[1, 2]]), viewport: viewport)
        XCTAssertEqual(stacked.frames[id(1)]?.width, 300)
    }

    func testOffKeepsTheColumnWidth() throws {
        let result = try ScrollableLayoutEngine(config: LayoutConfig(maximizeSingleWindow: false))
            .calculate(workspace: workspace([[1]]), viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.width, 300)
    }

    func testFloatingWindowsDoNotCountAsCompany() throws {
        let both = workspace([[1], [2]])
        let tiled = tilingWorkspace(from: both, modes: [id(2): .floating])
        let result = try engine.calculate(workspace: tiled, viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.width, 984)
    }

    func testConfigKeyIsOnByDefaultAndReachesTheEngine() throws {
        XCTAssertTrue(GioConfig().layout.maximizeSingleWindow)
        XCTAssertTrue(GioConfig().makeLayoutConfig().maximizeSingleWindow)
        let (off, warnings) = try parseGioConfig("[layout]\nmaximize-single-window = false\n").get()
        XCTAssertFalse(off.layout.maximizeSingleWindow)
        XCTAssertFalse(off.makeLayoutConfig().maximizeSingleWindow)
        XCTAssertTrue(warnings.isEmpty)
        guard case .failure = parseGioConfig("[layout]\nmaximize-single-window = \"yes\"\n") else {
            return XCTFail("a non-boolean must be rejected")
        }
    }

    func testTheLayoutFormTurnsItOffInTheFile() throws {
        var form = LayoutSettingsForm(config: LayoutSectionConfig())
        XCTAssertTrue(form.maximizeSingleWindow)
        form.maximizeSingleWindow = false
        guard case .success(let patched) = patchGioConfig("", edits: form.edits) else {
            return XCTFail("the edits must patch")
        }
        XCTAssertFalse(patched.config.layout.maximizeSingleWindow)
    }
}
