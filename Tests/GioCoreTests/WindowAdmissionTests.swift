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
            isPositionSettable: position, isSizeSettable: size,
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
}
