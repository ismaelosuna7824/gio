import XCTest
@testable import GioMacOS

/// WS-01: the SkyLight notification adapter resolves its private symbols at
/// runtime and names the missing ones (the notifications then stay off).
final class WindowServerEventSourceTests: XCTestCase {
    private let dummy = UnsafeMutableRawPointer(bitPattern: 0x1000)!

    func testAMissingSymbolIsNamedAndNothingIsBuilt() {
        let resolved = SkyLightEventSymbols.resolve { $0 == "SLSMainConnectionID" ? self.dummy : nil }
        XCTAssertNil(resolved.symbols)
        XCTAssertEqual(resolved.missing, ["SLSRegisterConnectionNotifyProc"])
    }

    func testAllSymbolsPresentBuildTheTable() {
        let resolved = SkyLightEventSymbols.resolve { _ in self.dummy }
        XCTAssertNotNil(resolved.symbols)
        XCTAssertEqual(resolved.missing, [])
    }
}
