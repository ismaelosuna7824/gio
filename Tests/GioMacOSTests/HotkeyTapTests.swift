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
        XCTAssertNil(tapCombo(from: keyEvent(keyCode: 10, flags: .maskAlternate)))
    }

    func testBareKeyParses() {
        XCTAssertEqual(
            tapCombo(from: keyEvent(keyCode: 40, flags: [])),
            HotkeyCombo(modifiers: [], key: "K")
        )
    }
}

/// HD-03: the keycode map and the shared key vocabulary must agree exactly.
final class HotkeyKeyTableTests: XCTestCase {
    func testEveryParseableKeyNameHasAKeycodeAndViceVersa() {
        XCTAssertEqual(Set(tapKeyCodes.keys), Set(supportedKeyNames))
    }

    func testKeycodesAreUnique() {
        XCTAssertEqual(Set(tapKeyCodes.values).count, tapKeyCodes.count)
    }

    func testEveryKeycodeMapsBackToItsName() {
        for (name, code) in tapKeyCodes {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
            event.flags = .maskAlternate
            XCTAssertEqual(tapCombo(from: event), HotkeyCombo(modifiers: [.alt], key: name), name)
        }
    }

    func testEveryTapKeyNameParsesAsAHotkey() {
        for name in tapKeyCodes.keys {
            XCTAssertEqual(parseHotkey("Alt+\(name)")?.key, name, name)
        }
    }

    /// DA-07: the shortcut recorder names NSEvent keycodes with the same table.
    func testRecorderKeyNamesComeFromTheSameTable() {
        for (name, code) in tapKeyCodes {
            XCTAssertEqual(hotkeyKeyName(forKeyCode: code), name, name)
        }
        XCTAssertNil(hotkeyKeyName(forKeyCode: 10))
    }
}

/// PF-AB: the tap runs on its own thread, so a click's location comes from
/// the event (global display space, top-left origin) instead of the
/// main-thread `NSEvent.mouseLocation`, in the Cocoa space window frames use.
final class TapLocationTests: XCTestCase {
    func testAClickIsReportedInCocoaCoordinates() throws {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 300, y: 200),
            mouseButton: .left
        ))
        XCTAssertEqual(tapCocoaLocation(of: event, primaryHeight: 1000), CGPoint(x: 300, y: 800))
    }
}
