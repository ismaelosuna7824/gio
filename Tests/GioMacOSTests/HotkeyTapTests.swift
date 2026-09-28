import CoreGraphics
import XCTest
@testable import GioCore
@testable import GioMacOS

/// Keycode and flag mapping for the tap. CGEvents construct headless —
/// only delivery needs permission.
final class HotkeyTapTests: XCTestCase {
    private func keyEvent(keyCode: Int64, flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true
        )!
        event.flags = flags
        return event
    }

    func testLettersAndDigits() {
        XCTAssertEqual(
            tapCombo(from: keyEvent(keyCode: 4, flags: .maskAlternate)),
            HotkeyCombo(modifiers: [.alt], key: "H")
        )
        XCTAssertEqual(
            tapCombo(from: keyEvent(keyCode: 19, flags: [.maskAlternate, .maskShift])),
            HotkeyCombo(modifiers: [.alt, .shift], key: "2")
        )
        XCTAssertEqual(
            tapCombo(from: keyEvent(keyCode: 49, flags: .maskAlternate)),
            HotkeyCombo(modifiers: [.alt], key: "Space")
        )
    }

    func testUnmappedKeycodesReturnNil() {
        XCTAssertNil(tapCombo(from: keyEvent(keyCode: 53, flags: .maskAlternate)))
    }

    func testBareKeyParses() {
        XCTAssertEqual(
            tapCombo(from: keyEvent(keyCode: 40, flags: [])),
            HotkeyCombo(modifiers: [], key: "K")
        )
    }
}
