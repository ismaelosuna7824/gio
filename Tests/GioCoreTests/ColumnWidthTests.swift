import XCTest
@testable import GioCore

/// NC-01: width specs, preset cycling (Niri rule) and percentage steps.
final class ColumnWidthTests: XCTestCase {
    private let viewport: CGFloat = 1000
    private let config = LayoutConfig(padding: 8, gap: 8)
    private let presets = defaultPresetColumnWidths

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func workspace(spec: ColumnWidthSpec = .standard) -> Workspace {
        Workspace(
            id: WorkspaceID(1),
            columns: [
                Column(id: ColumnID(1), width: 0, windows: [id(1)], widthSpec: spec),
                Column(id: ColumnID(2), width: 0, windows: [id(2)]),
            ],
            focusedColumn: 0,
            focusedWindow: id(1)
        )
    }

    private func resolved(_ workspace: Workspace, column: Int = 0) -> CGFloat {
        config.resolvedWidth(of: workspace.columns[column].widthSpec, viewportWidth: viewport)
    }

    func testLegacyWidthMapsToSpec() {
        XCTAssertEqual(Column(id: ColumnID(1), width: 0).widthSpec, .standard)
        XCTAssertEqual(Column(id: ColumnID(1), width: 300).widthSpec, .points(300))
        XCTAssertEqual(Column(id: ColumnID(1), width: 300).width, 300)
        XCTAssertEqual(Column(id: ColumnID(1), width: 0, widthSpec: .proportion(0.5)).width, 0)
    }

    func testResolvedWidthUsesNiriProportionSemantics() {
        XCTAssertEqual(config.resolvedWidth(of: .proportion(0.5), viewportWidth: 1000), 488, accuracy: 0.001)
        XCTAssertEqual(config.resolvedWidth(of: .proportion(1), viewportWidth: 1000), 984, accuracy: 0.001)
        XCTAssertEqual(config.resolvedWidth(of: .points(640), viewportWidth: 1000), 640)
        XCTAssertEqual(config.resolvedWidth(of: .standard, viewportWidth: 1000), 488, accuracy: 0.001)
        XCTAssertEqual(config.resolvedWidth(of: .points(50), viewportWidth: 1000), 200, "minimum wins")
    }

    func testEngineHonorsProportionSpec() throws {
        let engine = ScrollableLayoutEngine(config: config)
        let result = try engine.calculate(
            workspace: workspace(spec: .proportion(1)),
            viewport: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        XCTAssertEqual(result.frames[id(1)]!.width, 984, accuracy: 0.001)
    }

    func testPresetCycleFromDefaultGoesToNextLarger() {
        let next = switchPresetColumnWidth(
            in: workspace(), presets: presets, config: config, viewportWidth: viewport
        )
        // Default is half (488); the next larger preset is 2/3.
        XCTAssertEqual(next.columns[0].widthSpec, .proportion(0.66667))
        XCTAssertEqual(next.columns[1], workspace().columns[1])
    }

    func testPresetCycleWrapsToFirst() {
        let next = switchPresetColumnWidth(
            in: workspace(spec: .proportion(0.66667)), presets: presets,
            config: config, viewportWidth: viewport
        )
        XCTAssertEqual(next.columns[0].widthSpec, .proportion(0.33333))
    }

    func testPresetCycleFromSmallestGoesToHalf() {
        let next = switchPresetColumnWidth(
            in: workspace(spec: .proportion(0.33333)), presets: presets,
            config: config, viewportWidth: viewport
        )
        XCTAssertEqual(next.columns[0].widthSpec, .proportion(0.5))
    }

    func testPresetCycleSupportsPointPresetsAndEmptyIsNoOp() {
        let mixed: [ColumnWidthSpec] = [.points(300), .proportion(0.5)]
        let next = switchPresetColumnWidth(
            in: workspace(spec: .points(400)), presets: mixed, config: config, viewportWidth: viewport
        )
        XCTAssertEqual(next.columns[0].widthSpec, .proportion(0.5))
        let untouched = switchPresetColumnWidth(
            in: workspace(), presets: [], config: config, viewportWidth: viewport
        )
        XCTAssertEqual(untouched, workspace())
    }

    func testStepGrowsAndShrinksByTenPercent() {
        let grown = stepFocusedColumnWidth(
            in: workspace(), by: 0.1, config: config, viewportWidth: viewport
        )
        XCTAssertEqual(grown.columns[0].widthSpec, .proportion(0.6))
        let shrunk = stepFocusedColumnWidth(
            in: workspace(spec: .proportion(0.5)), by: -0.1, config: config, viewportWidth: viewport
        )
        guard case .proportion(let value) = shrunk.columns[0].widthSpec else {
            return XCTFail("expected proportion")
        }
        XCTAssertEqual(value, 0.4, accuracy: 0.0001)
    }

    func testStepClampsToMinimumAndFullWidth() {
        let full = stepFocusedColumnWidth(
            in: workspace(spec: .proportion(0.95)), by: 0.1, config: config, viewportWidth: viewport
        )
        XCTAssertEqual(full.columns[0].widthSpec, .proportion(1))
        let tiny = stepFocusedColumnWidth(
            in: workspace(spec: .proportion(0.25)), by: -0.5, config: config, viewportWidth: viewport
        )
        XCTAssertEqual(resolved(tiny), 200, accuracy: 0.001)
    }

    func testStepConvertsPointWidthsAndIgnoresEmptyWorkspace() {
        let stepped = stepFocusedColumnWidth(
            in: workspace(spec: .points(488)), by: 0.1, config: config, viewportWidth: viewport
        )
        XCTAssertEqual(stepped.columns[0].widthSpec, .proportion(0.6))
        let empty = Workspace(id: WorkspaceID(1))
        XCTAssertEqual(
            stepFocusedColumnWidth(in: empty, by: 0.1, config: config, viewportWidth: viewport), empty
        )
    }
}
