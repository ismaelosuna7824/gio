import XCTest
@testable import GioCore

/// HD-04: `center-focused-column` = never | always | on-overflow (Niri).
final class CenterFocusedColumnModeTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    private let engine = ScrollableLayoutEngine(config: LayoutConfig(defaultColumnWidth: 880))

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    /// Five 880-wide columns: column i spans 8 + 888 i ... 888 + 888 i; content 4448.
    private func workspace(focusedColumn: Int, offset: CGFloat = 0) -> Workspace {
        let columns = (1...5).map {
            Column(id: ColumnID(UInt64($0)), width: 0, windows: [id(UInt64($0))])
        }
        return Workspace(
            id: WorkspaceID(1), columns: columns, focusedColumn: focusedColumn,
            focusedWindow: id(UInt64(focusedColumn + 1)), viewportOffset: offset
        )
    }

    private func reveal(
        focus: Int, offset: CGFloat = 0, mode: CenterFocusedColumnMode, previous: Int? = nil
    ) throws -> CGFloat? {
        let ws = workspace(focusedColumn: focus, offset: offset)
        let layout = try engine.calculate(workspace: ws, viewport: viewport)
        return revealOffset(
            workspace: ws, layout: layout, viewport: viewport, edgeMargin: engine.config.padding,
            centering: CenterRequest(mode: mode, previouslyFocused: previous.map { id(UInt64($0 + 1)) })
        )
    }

    // MARK: Config

    func testDefaultIsOnOverflow() throws {
        XCTAssertEqual(LayoutSectionConfig().centerFocusedColumn, .onOverflow)
        let (config, _) = try parseGioConfig("[layout]\ngaps = 8\n").get()
        XCTAssertEqual(config.layout.centerFocusedColumn, .onOverflow)
    }

    func testParsesTheThreeStrings() throws {
        for (text, mode) in [("never", CenterFocusedColumnMode.never), ("always", .always), ("on-overflow", .onOverflow)] {
            let (config, warnings) = try parseGioConfig("[layout]\ncenter-focused-column = \"\(text)\"\n").get()
            XCTAssertEqual(config.layout.centerFocusedColumn, mode)
            XCTAssertTrue(warnings.isEmpty)
        }
    }

    func testLegacyBooleanKeepsWorking() throws {
        let on = try parseGioConfig("[layout]\ncenter-focused-column = true\n").get()
        XCTAssertEqual(on.0.layout.centerFocusedColumn, .always)
        let off = try parseGioConfig("[layout]\ncenter-focused-column = false\n").get()
        XCTAssertEqual(off.0.layout.centerFocusedColumn, .never)
    }

    func testUnknownValueIsRejectedWithAMessage() {
        guard case .failure(let errors) = parseGioConfig("[layout]\ncenter-focused-column = \"sometimes\"\n") else {
            return XCTFail("expected a validation error")
        }
        XCTAssertTrue(errors.messages.joined().contains("\"on-overflow\""))
    }

    // MARK: Reveal

    func testNeverKeepsTheMinimalScroll() throws {
        // Column 2 ends at 2664; the minimal scroll keeps the 8 pt padding.
        XCTAssertEqual(try XCTUnwrap(reveal(focus: 2, mode: .never)), 2664 + 8 - 1800, accuracy: 0.001)
    }

    func testAlwaysCentersTheFocusedColumn() throws {
        XCTAssertEqual(try XCTUnwrap(reveal(focus: 2, mode: .always)), 1324, accuracy: 0.001)
    }

    func testAlwaysCentersEvenWhenAlreadyVisible() throws {
        // Column 1 (896...1776) is fully visible at offset 0, and still centers.
        XCTAssertEqual(try XCTUnwrap(reveal(focus: 1, mode: .always)), 1336 - 900, accuracy: 0.001)
    }

    func testAlwaysClampsAtTheStripEdges() throws {
        XCTAssertNil(try reveal(focus: 0, mode: .always))
        XCTAssertEqual(try XCTUnwrap(reveal(focus: 4, mode: .always)), 4448 - 1800, accuracy: 0.001)
    }

    func testOnOverflowScrollsMinimallyWhenBothColumnsFit() throws {
        // Columns 1 and 2 together span 896...2664 = 1768 <= 1800.
        XCTAssertEqual(try XCTUnwrap(reveal(focus: 2, mode: .onOverflow, previous: 1)), 872, accuracy: 0.001)
    }

    func testOnOverflowCentersWhenTheyDoNotFitTogether() throws {
        // Columns 0 and 2 together span 8...2664 = 2656 > 1800.
        XCTAssertEqual(try XCTUnwrap(reveal(focus: 2, mode: .onOverflow, previous: 0)), 1324, accuracy: 0.001)
    }

    func testOnOverflowWithoutAPreviousColumnIsMinimal() throws {
        XCTAssertEqual(try XCTUnwrap(reveal(focus: 2, mode: .onOverflow)), 872, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(reveal(focus: 2, mode: .onOverflow, previous: 2)), 872, accuracy: 0.001)
    }

    func testPlannerAppliesTheCentering() throws {
        let planned = try planDisplayLayout(
            workspace: workspace(focusedColumn: 2), modes: [:], engine: engine,
            viewport: viewport, display: viewport, otherDisplays: [],
            centering: CenterRequest(mode: .always, previouslyFocused: nil)
        )
        XCTAssertEqual(planned.workspace.viewportOffset, 1324, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(planned.layout.frames[id(3)]).midX, 900, accuracy: 0.001)
    }

    func testCenteringNeverAffectsAPassiveReflow() throws {
        let planned = try planDisplayLayout(
            workspace: workspace(focusedColumn: 2, offset: 872), modes: [:], engine: engine,
            viewport: viewport, display: viewport, otherDisplays: []
        )
        XCTAssertEqual(planned.workspace.viewportOffset, 872, accuracy: 0.001)
    }

    func testFormEditWritesTheStringValue() {
        var form = LayoutSettingsForm(config: LayoutSectionConfig())
        form.centerFocusedColumn = .onOverflow
        XCTAssertTrue(form.edits.contains(.set(table: "layout", key: "center-focused-column", value: .string("on-overflow"))))
    }
}
