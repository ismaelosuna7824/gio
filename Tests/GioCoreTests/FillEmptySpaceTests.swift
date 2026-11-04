import XCTest
@testable import GioCore

/// NC-15 (OmniWM comparison 2026-11-04, user: "se adapta mejor"): while the
/// columns fit, they stretch proportionally to fill the strip; their stored
/// widths return as soon as they no longer fit. A resize by hand keeps its
/// width until a column is added or closed.
final class FillEmptySpaceTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
    /// 1000 - 2 * 8 padding - 8 gap: what two columns share.
    private let twoColumnsRoom: CGFloat = 976
    private let engine = ScrollableLayoutEngine(config: LayoutConfig(fillEmptySpace: true))

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func workspace(_ widths: [CGFloat]) -> Workspace {
        Workspace(id: WorkspaceID(1), columns: widths.enumerated().map { index, width in
            Column(id: ColumnID(UInt64(index + 1)), width: width, windows: [id(UInt64(index + 1))], focusedWindowIndex: 0)
        })
    }

    func testColumnsThatFitStretchProportionallyToFillTheStrip() throws {
        let result = try engine.calculate(workspace: workspace([200, 400]), viewport: viewport)
        let first = try XCTUnwrap(result.frames[id(1)]?.width)
        let second = try XCTUnwrap(result.frames[id(2)]?.width)
        XCTAssertEqual(first + second, twoColumnsRoom, accuracy: 0.01)
        XCTAssertEqual(second / first, 2, accuracy: 0.001, "relative sizes kept")
        XCTAssertEqual(result.contentWidth, 1000, accuracy: 0.01)
    }

    func testColumnsThatOverflowKeepTheirWidths() throws {
        let result = try engine.calculate(workspace: workspace([500, 500, 500]), viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.width, 500)
        XCTAssertEqual(result.frames[id(3)]?.width, 500)
    }

    /// A rule's `max-width` caps a column; the others take what it leaves.
    func testAColumnAtItsMaximumLeavesTheRestToTheOthers() throws {
        let limited = ScrollableLayoutEngine(
            config: LayoutConfig(fillEmptySpace: true),
            widthLimits: [id(1): ColumnWidthLimits(min: nil, max: 300)]
        )
        let result = try limited.calculate(workspace: workspace([300, 300]), viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.width, 300)
        XCTAssertEqual(try XCTUnwrap(result.frames[id(2)]?.width), twoColumnsRoom - 300, accuracy: 0.01)
    }

    /// A lone window is `maximize-single-window`'s, not this option's.
    func testALoneColumnIsLeftToMaximizeSingleWindow() throws {
        let result = try engine.calculate(workspace: workspace([300]), viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.width, 300)
    }

    func testOffLeavesTheEmptySpace() throws {
        let result = try ScrollableLayoutEngine().calculate(workspace: workspace([300, 300]), viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.width, 300)
    }

    func testAResizeByHandKeepsItsWidthUntilTheColumnCountChanges() throws {
        var resized = stepFocusedColumnWidth(
            in: workspace([300, 300]), by: 0.1, config: engine.config, viewportWidth: viewport.width
        )
        XCTAssertEqual(resized.fillPausedAtColumnCount, 2)
        let paused = try engine.calculate(workspace: resized, viewport: viewport)
        let pausedFirst = try XCTUnwrap(paused.frames[id(1)]?.width)
        let pausedSecond = try XCTUnwrap(paused.frames[id(2)]?.width)
        XCTAssertLessThan(pausedFirst + pausedSecond, twoColumnsRoom)

        resized.columns.append(Column(id: ColumnID(3), width: 100, windows: [id(3)], focusedWindowIndex: 0))
        resized.reconcileFillPause()
        XCTAssertNil(resized.fillPausedAtColumnCount, "a window added: filling resumes")
    }

    func testPresetCyclingPausesTheFillToo() {
        let cycled = switchPresetColumnWidth(
            in: workspace([300, 300]), presets: defaultPresetColumnWidths, config: engine.config,
            viewportWidth: viewport.width
        )
        XCTAssertEqual(cycled.fillPausedAtColumnCount, 2)
    }

    func testConfigKeyIsOnByDefaultAndReachesTheEngine() throws {
        XCTAssertTrue(GioConfig().layout.fillEmptySpace)
        XCTAssertTrue(GioConfig().makeLayoutConfig().fillEmptySpace)
        let (config, messages) = try parseGioConfig("[layout]\nfill-empty-space = false\n").get()
        XCTAssertEqual(messages, [])
        XCTAssertFalse(config.layout.fillEmptySpace)
    }
}
