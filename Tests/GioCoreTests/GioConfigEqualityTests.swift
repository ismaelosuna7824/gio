import XCTest
@testable import GioCore

/// PA-12: the UI skips republishing an unchanged session snapshot, so
/// config equality must see every setting, keybindings included.
final class GioConfigEqualityTests: XCTestCase {
    private let altH = HotkeyCombo(modifiers: [.alt], key: "H")
    private let altL = HotkeyCombo(modifiers: [.alt], key: "L")

    func testDefaultsAreEqual() {
        XCTAssertEqual(GioConfig(), GioConfig())
    }

    func testKeybindingsCompareByContentAndOrder() {
        let bindings: [(HotkeyCombo, HotkeyAction)] = [(altH, .focusLeft), (altL, .focusRight)]
        XCTAssertEqual(GioConfig(keybindings: bindings), GioConfig(keybindings: bindings))
        XCTAssertNotEqual(
            GioConfig(keybindings: bindings), GioConfig(keybindings: bindings.reversed()), "file order matters"
        )
        XCTAssertNotEqual(
            GioConfig(keybindings: [(altH, .focusLeft)]), GioConfig(keybindings: [(altH, .focusRight)]), "action"
        )
        XCTAssertNotEqual(
            GioConfig(keybindings: [(altH, .focusLeft)]), GioConfig(keybindings: [(altL, .focusLeft)]), "combo"
        )
        XCTAssertNotEqual(GioConfig(keybindings: bindings), GioConfig(keybindings: [(altH, .focusLeft)]), "count")
    }

    func testEverySectionTakesPart() {
        let base = GioConfig()
        var changes: [GioConfig] = []
        func changed(_ edit: (inout GioConfig) -> Void) {
            var config = base
            edit(&config)
            changes.append(config)
        }
        changed { $0.layout.gaps += 1 }
        changed { $0.behavior.focusFollowsMouse.toggle() }
        changed { $0.animations.enabled.toggle() }
        changed { $0.focusRing.enabled.toggle() }
        changed { $0.focus.dimStrength += 0.1 }
        changed { $0.logging.level = base.logging.level == .debug ? .info : .debug }
        changed { $0.keybindings = [(self.altH, .focusLeft)] }
        changed { $0.unboundKeys = [self.altH] }
        changed { $0.rules = [WindowRule(app: "Finder")] }
        changed { $0.workspaces = [WorkspaceDefinition(name: "code")] }
        changed { $0.dwindle.defaultSplitRatio += 0.1 }
        changed { $0.gestures.scroll.toggle() }
        for (index, config) in changes.enumerated() {
            XCTAssertNotEqual(config, base, "change \(index) is ignored by ==")
        }
        XCTAssertEqual(
            Mirror(reflecting: base).children.count, changes.count,
            "a new stored property must join GioConfig == and this test"
        )
    }
}
