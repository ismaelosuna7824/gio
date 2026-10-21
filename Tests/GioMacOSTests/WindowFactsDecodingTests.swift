import ApplicationServices
import XCTest
import GioCore
@testable import GioMacOS

/// PA-18a: discovery reads a window's facts in one batched message; each
/// slot is a value or an `.axError` `AXValue`, decoded with the meaning the
/// single-attribute reads had. No Accessibility permission needed.
final class WindowFactsDecodingTests: XCTestCase {
    private func point(_ x: CGFloat, _ y: CGFloat) -> AnyObject {
        var point = CGPoint(x: x, y: y)
        return AXValueCreate(.cgPoint, &point)!
    }

    private func size(_ width: CGFloat, _ height: CGFloat) -> AnyObject {
        var size = CGSize(width: width, height: height)
        return AXValueCreate(.cgSize, &size)!
    }

    private func error(_ code: AXError) -> AnyObject {
        var code = code
        return AXValueCreate(.axError, &code)!
    }

    /// Slot order: position, size, minimized, AXFullScreen, AXFullscreen,
    /// role, subrole, title.
    private func slots(
        position: AnyObject? = nil, size extent: AnyObject? = nil,
        minimized: AnyObject = NSNumber(value: false), fullScreen: AnyObject? = nil, fullscreen: AnyObject? = nil,
        role: AnyObject = "AXWindow" as NSString, subrole: AnyObject = "AXStandardWindow" as NSString,
        title: AnyObject = "secret" as NSString
    ) -> [AnyObject] {
        [
            position ?? point(10, 20), extent ?? size(800, 600), minimized,
            fullScreen ?? error(.attributeUnsupported), fullscreen ?? error(.attributeUnsupported),
            role, subrole, title,
        ]
    }

    func testEverySlotReadable() {
        let facts = decodeWindowFacts(status: .success, values: slots(fullScreen: NSNumber(value: true)))
        XCTAssertEqual(facts, AXWindowFacts(
            frame: CGRect(x: 10, y: 20, width: 800, height: 600), minimized: false, fullscreen: true,
            role: "AXWindow", subrole: "AXStandardWindow", title: "secret",
            roleReadable: true, elementGone: false
        ))
    }

    func testFullscreenFallsBackToTheOtherSpelling() {
        XCTAssertEqual(
            decodeWindowFacts(status: .success, values: slots(fullscreen: NSNumber(value: true))).fullscreen, true
        )
        XCTAssertNil(decodeWindowFacts(status: .success, values: slots()).fullscreen)
    }

    func testAnUnreadableSlotIsNilAndLeavesTheOthers() {
        let facts = decodeWindowFacts(status: .success, values: slots(
            size: error(.cannotComplete), minimized: error(.noValue), subrole: error(.noValue), title: "" as NSString
        ))
        XCTAssertNil(facts.frame, "a frame needs both position and size")
        XCTAssertNil(facts.minimized)
        XCTAssertNil(facts.subrole)
        XCTAssertNil(facts.title, "an empty title is no title")
        XCTAssertEqual(facts.role, "AXWindow")
        XCTAssertTrue(facts.roleReadable)
    }

    func testAnEmptyOrNonFiniteFrameIsUnreadable() {
        XCTAssertNil(decodeWindowFacts(status: .success, values: slots(size: size(0, 600))).frame)
        XCTAssertNil(decodeWindowFacts(status: .success, values: slots(position: point(.nan, 0))).frame)
    }

    func testAnUnreadableRoleIsNotGone() {
        let facts = decodeWindowFacts(status: .success, values: slots(role: error(.cannotComplete)))
        XCTAssertNil(facts.role)
        XCTAssertFalse(facts.roleReadable)
        XCTAssertFalse(facts.elementGone)
    }

    func testAnInvalidRoleSlotMeansTheElementIsGone() {
        let facts = decodeWindowFacts(status: .success, values: slots(role: error(.invalidUIElement)))
        XCTAssertTrue(facts.elementGone)
        XCTAssertFalse(facts.roleReadable)
    }

    func testAFailedCallFailsEverySlot() {
        let gone = decodeWindowFacts(status: .invalidUIElement, values: nil)
        XCTAssertEqual(gone, AXWindowFacts(
            frame: nil, minimized: nil, fullscreen: nil, role: nil, subrole: nil, title: nil,
            roleReadable: false, elementGone: true
        ))
        let busy = decodeWindowFacts(status: .cannotComplete, values: nil)
        XCTAssertFalse(busy.elementGone)
        XCTAssertFalse(busy.roleReadable)
        XCTAssertNil(busy.frame)
    }

    func testAShortAnswerIsAFailedCall() {
        let facts = decodeWindowFacts(status: .success, values: Array(slots().prefix(2)))
        XCTAssertNil(facts.frame)
        XCTAssertFalse(facts.roleReadable)
        XCTAssertFalse(facts.elementGone)
    }
}
