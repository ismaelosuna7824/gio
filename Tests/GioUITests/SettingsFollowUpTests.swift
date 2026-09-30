import GioCore
import XCTest
@testable import GioUI

/// DD-03 follow-ups: preset-width chips (labels, editor parsing, config
/// text) and the per-section shelf that keeps unsaved drafts.
final class SettingsFollowUpTests: XCTestCase {
    // MARK: - Preset width chips

    func testChipLabelsReadAsPercentOrPoints() {
        XCTAssertEqual(presetWidthLabel(0.33333), "33%")
        XCTAssertEqual(presetWidthLabel(0.5), "50%")
        XCTAssertEqual(presetWidthLabel(0.66667), "67%")
        XCTAssertEqual(presetWidthLabel(1), "100%")
        XCTAssertEqual(presetWidthLabel(800), "800 pt")
    }

    func testChipValuesComeFromTheConfigText() {
        XCTAssertEqual(presetWidthValues("0.33333, 0.5, 0.66667"), [0.33333, 0.5, 0.66667])
        XCTAssertEqual(presetWidthValues("0.5, wide"), [])
        XCTAssertEqual(presetWidthValues(""), [])
    }

    func testChipsWriteTheSameNumbersBack() {
        let text = presetWidthsText([0.33333, 0.5, 800])
        XCTAssertEqual(text, "0.33333, 0.5, 800")
        XCTAssertEqual(parsePresetList(text), [0.33333, 0.5, 800])
        XCTAssertEqual(presetWidthsText([]), "")
    }

    func testEditorSeedsFromAValue() {
        XCTAssertEqual(PresetWidthEditorValue(value: 0.33333), PresetWidthEditorValue(amount: "33.333", unit: .percent))
        XCTAssertEqual(PresetWidthEditorValue(value: 0.5), PresetWidthEditorValue(amount: "50", unit: .percent))
        XCTAssertEqual(PresetWidthEditorValue(value: 800), PresetWidthEditorValue(amount: "800", unit: .points))
        XCTAssertEqual(PresetWidthEditorValue(value: nil), PresetWidthEditorValue(amount: "50", unit: .percent))
    }

    func testEditorResolvesPercentAndPoints() {
        XCTAssertEqual(PresetWidthEditorValue(amount: "33.333", unit: .percent).resolved, 0.33333)
        XCTAssertEqual(PresetWidthEditorValue(amount: " 75 ", unit: .percent).resolved, 0.75)
        XCTAssertEqual(PresetWidthEditorValue(amount: "100", unit: .percent).resolved, 1)
        XCTAssertEqual(PresetWidthEditorValue(amount: "800", unit: .points).resolved, 800)
        XCTAssertEqual(PresetWidthEditorValue(amount: "75%", unit: .percent).resolved, 0.75)
        XCTAssertEqual(PresetWidthEditorValue(amount: "640 pt", unit: .points).resolved, 640)
    }

    func testEditorRejectsOutOfRangeAndGarbage() {
        let cases: [PresetWidthEditorValue] = [
            PresetWidthEditorValue(amount: "0", unit: .percent),
            PresetWidthEditorValue(amount: "120", unit: .percent),
            PresetWidthEditorValue(amount: "1", unit: .points),
            PresetWidthEditorValue(amount: "wide", unit: .points),
            PresetWidthEditorValue(amount: "", unit: .percent),
            PresetWidthEditorValue(amount: "nan", unit: .percent),
        ]
        for value in cases {
            XCTAssertNil(value.resolved, "\(value)")
            XCTAssertNotNil(value.problem, "\(value)")
        }
        XCTAssertNil(PresetWidthEditorValue(amount: "50", unit: .percent).problem)
    }

    func testPreviewRulerUsesTheChipLabels() {
        var form = LayoutSettingsForm(config: LayoutSectionConfig())
        form.presetsText = "0.33333, 800"
        XCTAssertEqual(layoutPreviewGeometry(form, mode: .columns).presetLabels, ["33%", "800 pt"])
    }

    // MARK: - Draft shelf

    private func draft(saved: Int, current: Int) -> SettingsDraft<Int> {
        var draft = SettingsDraft(saved: saved)
        draft.current = current
        return draft
    }

    func testDirtyDraftIsKeptAndRestored() {
        var shelf = SettingsDraftShelf()
        shelf.store(draft(saved: 1, current: 5), for: .layout)
        XCTAssertEqual(shelf.dirtySections, [.layout])
        XCTAssertTrue(shelf.hasUnsavedEdits(.layout))
        let restored = shelf.restore(for: .layout, saved: 1)
        XCTAssertEqual(restored.current, 5)
        XCTAssertTrue(restored.isDirty)
    }

    func testCleanDraftClearsTheShelf() {
        var shelf = SettingsDraftShelf()
        shelf.store(draft(saved: 1, current: 5), for: .layout)
        shelf.store(draft(saved: 1, current: 1), for: .layout)
        XCTAssertTrue(shelf.dirtySections.isEmpty)
        XCTAssertEqual(shelf.restore(for: .layout, saved: 1), SettingsDraft(saved: 1))
    }

    func testRestoreWithoutADraftStartsFromSaved() {
        let shelf = SettingsDraftShelf()
        XCTAssertEqual(shelf.restore(for: .focus, saved: "a"), SettingsDraft(saved: "a"))
    }

    func testRestoreAdoptsANewerSavedValueAndKeepsTheEdit() {
        var shelf = SettingsDraftShelf()
        shelf.store(draft(saved: 1, current: 5), for: .animations)
        let restored = shelf.restore(for: .animations, saved: 2)
        XCTAssertEqual(restored.saved, 2)
        XCTAssertEqual(restored.current, 5)
    }

    func testRestoreWithAnotherTypeStartsFresh() {
        var shelf = SettingsDraftShelf()
        shelf.store(draft(saved: 1, current: 5), for: .layout)
        XCTAssertEqual(shelf.restore(for: .layout, saved: "x"), SettingsDraft(saved: "x"))
    }

    func testSectionsAreIndependent() {
        var shelf = SettingsDraftShelf()
        shelf.store(draft(saved: 1, current: 2), for: .layout)
        shelf.store(draft(saved: 1, current: 3), for: .focus)
        shelf.discard(.layout)
        XCTAssertEqual(shelf.dirtySections, [.focus])
        XCTAssertEqual(shelf.restore(for: .focus, saved: 1).current, 3)
    }
}

final class RulerLaneTests: XCTestCase {
    func testCloseLabelsDropToASecondRow() {
        XCTAssertEqual(rulerLabelLanes([100, 200, 300], minimumSpacing: 40), [0, 0, 0])
        XCTAssertEqual(rulerLabelLanes([100, 120, 300], minimumSpacing: 40), [0, 1, 0])
        // Order follows position, not input order.
        XCTAssertEqual(rulerLabelLanes([120, 100], minimumSpacing: 40), [1, 0])
        XCTAssertEqual(rulerLabelLanes([], minimumSpacing: 40), [])
    }
}
