import ApplicationServices
import CoreGraphics
import XCTest
@testable import GioCore
@testable import GioMacOS

/// PF-L: the SkyLight adapter resolves its private symbols at runtime and
/// reports the missing ones (the WindowServer transport then stays off);
/// frames cross into SkyLight's top-left space only here.
final class SkyLightTests: XCTestCase {
    private let dummy = UnsafeMutableRawPointer(bitPattern: 0x1000)!

    func testEveryMissingSymbolIsNamedAndNothingIsBuilt() {
        let present: Set<String> = ["SLSMainConnectionID", "SLSTransactionCommit"]
        let resolved = SkyLightSymbols.resolve { present.contains($0) ? self.dummy : nil }
        XCTAssertNil(resolved.symbols)
        XCTAssertEqual(resolved.missing, ["SLSTransactionCreate", "SLSTransactionMoveWindowWithGroup"])
    }

    func testAllSymbolsPresentBuildTheTable() {
        let resolved = SkyLightSymbols.resolve { _ in self.dummy }
        XCTAssertNotNil(resolved.symbols)
        XCTAssertTrue(resolved.missing.isEmpty)
    }

    func testLoadingReportsAMoverOnlyWithoutMissingSymbols() {
        let loaded = SkyLightWindowMover.load(windowIDs: { _ in nil }, flip: { AXVerticalFlip(displayHeight: 1000) })
        XCTAssertEqual(loaded.mover == nil, !loaded.missing.isEmpty)
    }

    func testCocoaFramesBecomeTopLeftOriginsForTheWindowServer() {
        let flip = AXVerticalFlip(displayHeight: 1000)
        XCTAssertEqual(
            windowServerOrigin(of: CGRect(x: 100, y: 50, width: 400, height: 300), flip: flip),
            CGPoint(x: 100, y: 650)
        )
        // A window parked below the display: its top is at the bottom edge.
        XCTAssertEqual(
            windowServerOrigin(of: CGRect(x: 1799, y: -983, width: 700, height: 984), flip: flip),
            CGPoint(x: 1799, y: 999)
        )
    }

    func testTheActuatorKnowsNoWindowServerIDForUnknownOrOwnWindows() {
        let actuator = AXWindowActuator(displayHeight: 1000)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let element = AXUIElementCreateApplication(ownPID)
        actuator.register(elementID: 1, pid: ownPID, element: element, appElement: element)
        XCTAssertNil(actuator.windowServerID(of: WindowID(pid: ownPID, elementID: 1)))
        XCTAssertNil(actuator.windowServerID(of: WindowID(pid: ownPID &+ 1, elementID: 2)))
    }
}
