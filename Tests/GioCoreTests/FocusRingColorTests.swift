import XCTest
@testable import GioCore

final class FocusRingColorTests: XCTestCase {
    func testNormalizesEveryAcceptedSpelling() {
        for input in ["#ABC", "abc", "#AABBCC", "aabbcc", "  #aAbBcC "] {
            XCTAssertEqual(try normalizedHexColor(input).get(), "#aabbcc", input)
        }
    }

    func testRejectsInvalidInputWithAMessage() {
        for input in ["", "#", "nope", "#12", "#12345", "#1234567", "#ggg", "#7fc8ffaa"] {
            switch normalizedHexColor(input) {
            case .success(let hex):
                XCTFail("\(input) should be rejected, got \(hex)")
            case .failure(let error):
                XCTAssertFalse(error.message.isEmpty, input)
            }
        }
    }

    func testHexToComponentsAndBack() throws {
        let color = try XCTUnwrap(ThemeColor(hex: "#7fc8ff"))
        let bytes = color.rgbBytes
        XCTAssertEqual([bytes.red, bytes.green, bytes.blue], [0x7f, 0xc8, 0xff])
        XCTAssertEqual(ThemeColor(rgbBytes: bytes), color)
        XCTAssertEqual(color.lowercaseHex, "#7fc8ff")
    }

    func testEveryByteValueRoundTrips() {
        for value in 0...255 {
            let byte = UInt8(value)
            let color = ThemeColor(rgbBytes: RGBBytes(red: byte, green: 255 - byte, blue: byte / 2))
            XCTAssertEqual(color.rgbBytes, RGBBytes(red: byte, green: 255 - byte, blue: byte / 2))
            XCTAssertEqual(ThemeColor(hex: color.lowercaseHex), color)
        }
    }

    func testComponentsClampOutOfRangeValues() {
        let color = ThemeColor(red: 1.4, green: -0.2, blue: 0.5)
        XCTAssertEqual(color.rgbBytes, RGBBytes(red: 255, green: 0, blue: 128))
    }

    func testPresetsStartWithNiriDefaultAndAreValidUniqueLowercase() {
        XCTAssertEqual(focusRingColorPresets.first, "#7fc8ff")
        XCTAssertEqual(Set(focusRingColorPresets).count, focusRingColorPresets.count)
        for preset in focusRingColorPresets {
            XCTAssertEqual(try normalizedHexColor(preset).get(), preset)
        }
    }

    func testFormEditsWriteLowercaseSixDigitHex() throws {
        var form = FocusRingSettingsForm(config: FocusRingSectionConfig())
        form.colorText = "#ABC"
        let result = try patchGioConfig(defaultConfigTemplate(), edits: form.edits).get()
        XCTAssertTrue(result.text.contains("active-color = \"#aabbcc\""))
    }

    func testFormSetColorNormalizesAndKeepsInvalidTextVisible() {
        var form = FocusRingSettingsForm(config: FocusRingSectionConfig())
        form.setColor(ThemeColor(hex: "#F38BA8")!)
        XCTAssertEqual(form.colorText, "#f38ba8")
        XCTAssertEqual(form.color, ThemeColor(hex: "#f38ba8"))
        form.colorText = "zzz"
        XCTAssertNil(form.color)
    }
}
