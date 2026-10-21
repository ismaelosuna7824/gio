import XCTest
@testable import GioCore

final class WindowAdmissionTests: XCTestCase {
    private func facts(
        role: String? = "AXWindow",
        subrole: String? = "AXStandardWindow",
        position: Bool = true,
        size: Bool = true,
        fullscreen: Bool = false,
        minimized: Bool = false,
        validFrame: Bool = true
    ) -> WindowAdmissionFacts {
        WindowAdmissionFacts(
            role: role, subrole: subrole,
            isPositionSettable: { position }, isSizeSettable: { size },
            isFullscreen: fullscreen, isMinimized: minimized, hasValidFrame: validFrame
        )
    }

    func testStandardResizableTiles() {
        XCTAssertEqual(classifyWindowAdmission(facts()), .tile)
    }

    func testStandardNonResizableFloats() {
        XCTAssertEqual(classifyWindowAdmission(facts(size: false)), .float(.notResizable))
        XCTAssertEqual(classifyWindowAdmission(facts(position: false)), .float(.notResizable))
    }

    func testEmptySubroleResizableTiles() {
        XCTAssertEqual(classifyWindowAdmission(facts(subrole: "")), .tile)
        XCTAssertEqual(classifyWindowAdmission(facts(subrole: nil)), .tile)
    }

    func testUnknownSubroleResizableTiles() {
        XCTAssertEqual(classifyWindowAdmission(facts(subrole: "AXUnknown")), .tile)
    }

    func testUnknownSubroleNonResizableFloats() {
        XCTAssertEqual(classifyWindowAdmission(facts(subrole: "", size: false)), .float(.notResizable))
        XCTAssertEqual(
            classifyWindowAdmission(facts(subrole: "AXUnknown", position: false)),
            .float(.notResizable)
        )
    }

    func testDialogsFloat() {
        XCTAssertEqual(classifyWindowAdmission(facts(subrole: "AXDialog")), .float(.dialog))
        XCTAssertEqual(classifyWindowAdmission(facts(subrole: "AXSystemDialog")), .float(.dialog))
    }

    func testFloatingSubrolesFloat() {
        XCTAssertEqual(
            classifyWindowAdmission(facts(subrole: "AXFloatingWindow")), .float(.floatingSubrole)
        )
        XCTAssertEqual(
            classifyWindowAdmission(facts(subrole: "AXSystemFloatingWindow")),
            .float(.floatingSubrole)
        )
    }

    func testSheetsAndPopoversAreIgnored() {
        XCTAssertEqual(classifyWindowAdmission(facts(subrole: "AXSheet")), .ignore(.sheetOrPopover))
        XCTAssertEqual(classifyWindowAdmission(facts(subrole: "AXPopover")), .ignore(.sheetOrPopover))
    }

    func testNonWindowRolesAreIgnored() {
        XCTAssertEqual(classifyWindowAdmission(facts(role: "AXSheet")), .ignore(.notAWindow))
        XCTAssertEqual(classifyWindowAdmission(facts(role: "AXPopover")), .ignore(.notAWindow))
        XCTAssertEqual(classifyWindowAdmission(facts(role: nil)), .ignore(.notAWindow))
    }

    func testInvalidFrameIsIgnored() {
        XCTAssertEqual(classifyWindowAdmission(facts(validFrame: false)), .ignore(.invalidFrame))
    }

    func testFullscreenAndMinimizedAreSuspendedNotIgnored() {
        XCTAssertEqual(classifyWindowAdmission(facts(fullscreen: true)), .suspend(.fullscreen))
        XCTAssertEqual(classifyWindowAdmission(facts(minimized: true)), .suspend(.minimized))
    }

    func testDialogStaysFloatingEvenWhenMinimized() {
        XCTAssertEqual(
            classifyWindowAdmission(facts(subrole: "AXDialog", minimized: true)), .float(.dialog)
        )
    }

    func testLabelsAreStable() {
        XCTAssertEqual(WindowAdmission.tile.label, "tile")
        XCTAssertEqual(WindowAdmission.float(.notResizable).label, "float(notResizable)")
        XCTAssertEqual(WindowAdmission.ignore(.sheetOrPopover).label, "ignore(sheetOrPopover)")
        XCTAssertEqual(WindowAdmission.suspend(.minimized).label, "suspend(minimized)")
    }

    /// PA-18a: the settable probes are Accessibility messages; they run only
    /// when every earlier rule passed, each at most once.
    func testSettableProbesRunOnlyWhenEveryEarlierRulePassed() {
        var probes: [String] = []
        func probed(
            role: String? = "AXWindow", subrole: String? = "AXStandardWindow", position: Bool = true,
            fullscreen: Bool = false, minimized: Bool = false, validFrame: Bool = true
        ) -> WindowAdmission {
            classifyWindowAdmission(WindowAdmissionFacts(
                role: role, subrole: subrole,
                isPositionSettable: {
                    probes.append("position")
                    return position
                },
                isSizeSettable: {
                    probes.append("size")
                    return true
                },
                isFullscreen: fullscreen, isMinimized: minimized, hasValidFrame: validFrame
            ))
        }
        XCTAssertEqual(probed(role: "AXSheet"), .ignore(.notAWindow))
        XCTAssertEqual(probed(subrole: "AXSheet"), .ignore(.sheetOrPopover))
        XCTAssertEqual(probed(subrole: "AXDialog"), .float(.dialog))
        XCTAssertEqual(probed(subrole: "AXFloatingWindow"), .float(.floatingSubrole))
        XCTAssertEqual(probed(validFrame: false), .ignore(.invalidFrame))
        XCTAssertEqual(probed(fullscreen: true), .suspend(.fullscreen))
        XCTAssertEqual(probed(minimized: true), .suspend(.minimized))
        XCTAssertEqual(probes, [], "no probe before the resizability rule")

        XCTAssertEqual(probed(), .tile)
        XCTAssertEqual(probes, ["position", "size"], "each probe once when reached")

        probes = []
        XCTAssertEqual(probed(position: false), .float(.notResizable))
        XCTAssertEqual(probes, ["position"], "a fixed position settles it without the size probe")
    }
}

/// MM-12: an admission float (dialog, floating subrole, fixed size) whose
/// window now reads as a normal resizable window goes back to the grid; a
/// float the user, a rule or a snap-back chose never does.
final class AdmissionFloatPromotionTests: XCTestCase {
    private func window(_ mode: WindowMode, _ reason: FloatReason?) -> ManagedWindow {
        var window = ManagedWindow(
            id: WindowID(pid: 1, elementID: 1), pid: 1, application: "Music", title: "",
            frame: CGRect(x: 16, y: 0, width: 1784, height: 1114), mode: mode
        )
        window.floatReason = reason
        return window
    }

    func testAnAdmissionFloatThatNowTilesIsPromoted() {
        for reason in [FloatReason.dialog, .floatingSubrole, .notResizable] {
            XCTAssertTrue(promotesAdmissionFloat(window(.floating, reason), to: .tile), "\(reason)")
        }
    }

    func testAChosenFloatOrAStillFloatingWindowIsNotPromoted() {
        for reason in [FloatReason.manual, .rule, .appControlled] {
            XCTAssertFalse(promotesAdmissionFloat(window(.floating, reason), to: .tile), "\(reason)")
        }
        XCTAssertFalse(promotesAdmissionFloat(window(.floating, .dialog), to: .float(.dialog)))
        XCTAssertFalse(promotesAdmissionFloat(window(.floating, .dialog), to: .suspend(.minimized)))
        XCTAssertFalse(promotesAdmissionFloat(window(.tiled, nil), to: .tile))
    }
}
