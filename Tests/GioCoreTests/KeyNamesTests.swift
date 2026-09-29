import XCTest
@testable import GioCore

/// HD-03: one shared key vocabulary. Every name parses to itself, aliases fold
/// into it, and unknown names are rejected with a message instead of parsing.
final class KeyNamesTests: XCTestCase {
    func testVocabularyHasNoDuplicatesAndTheFullAnsiSet() {
        let names = supportedKeyNames
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names.count, 72)
        let required: [String] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").map(String.init)
            + (1...12).map { "F\($0)" }
            + ["Left", "Right", "Up", "Down", "Tab", "Return", "Escape", "Space", "Delete",
               "Grave", "Comma", "Period", "Slash", "Semicolon", "Quote", "Backslash", "Minus", "Equal",
               "BracketLeft", "BracketRight", "Home", "End", "PageUp", "PageDown"]
        XCTAssertEqual(Set(names), Set(required))
    }

    func testEveryCanonicalNameParsesToItself() {
        for name in supportedKeyNames {
            XCTAssertEqual(parseHotkey("Alt+\(name)")?.key, name, name)
            XCTAssertEqual(parseHotkey("Alt+\(name.lowercased())")?.key, name, name)
        }
    }

    func testAliasesFoldIntoCanonicalNames() {
        let expected: [String: String] = [
            "-": "Minus", "=": "Equal", "[": "BracketLeft", "]": "BracketRight",
            ";": "Semicolon", "'": "Quote", ",": "Comma", ".": "Period", "/": "Slash",
            "\\": "Backslash", "`": "Grave", "esc": "Escape", "enter": "Return",
            "backspace": "Delete", "pgup": "PageUp", "pgdn": "PageDown", "h": "H",
        ]
        for (raw, name) in expected {
            XCTAssertEqual(parseHotkey("Alt+\(raw)")?.key, name, raw)
        }
    }

    func testUnknownKeyNamesDoNotParse() {
        for raw in ["Foo", "F13", "F0", "Enterprise", "é", "HH", "10"] {
            XCTAssertNil(parseHotkey("Alt+\(raw)"), raw)
        }
    }

    func testExplainsUnknownKeysAndKeepsModifierFailuresDistinct() {
        XCTAssertEqual(hotkeyFailure("Alt+Foo"), .unknownKey("Foo"))
        XCTAssertEqual(hotkeyFailure("Win+H"), .unparseable)
        XCTAssertEqual(hotkeyFailure("H"), .unparseable)
        XCTAssertNil(hotkeyFailure("Alt+H"))
    }

    func testConfigBindingOnUnknownKeyIsReported() {
        let result = parseGioConfig("[keybindings]\n\"Alt+Foo\" = \"focus-left\"\n")
        guard case .failure(let errors) = result else {
            return XCTFail("expected a validation failure")
        }
        XCTAssertTrue(errors.messages.contains { $0.contains("unknown key 'Foo'") }, "\(errors.messages)")
    }

    func testConfigBindingOnNewKeyIsAccepted() {
        let result = parseGioConfig("[keybindings]\n\"Alt+Y\" = \"focus-left\"\n\"Ctrl+F5\" = \"focus-right\"\n")
        guard case .success(let parsed) = result else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(parsed.0.keybindings.count, 2)
    }
}
