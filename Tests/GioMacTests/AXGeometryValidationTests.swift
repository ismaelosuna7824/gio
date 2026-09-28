import CoreGraphics
import XCTest
@testable import GioMac

final class AXGeometryValidationTests: XCTestCase {
    func testRejectsInvalidFrameWithoutAX() {
        XCTAssertTrue(AXGeometryValidation.isValidFrame(origin: CGPoint(x: -20, y: 30), size: CGSize(width: 40, height: 50)))
        XCTAssertFalse(AXGeometryValidation.isValidFrame(origin: CGPoint(x: CGFloat.nan, y: 0), size: CGSize(width: 40, height: 50)))
        XCTAssertFalse(AXGeometryValidation.isValidFrame(origin: .zero, size: CGSize(width: CGFloat.infinity, height: 50)))
        XCTAssertFalse(AXGeometryValidation.isValidFrame(origin: .zero, size: CGSize(width: 0, height: 50)))
        XCTAssertFalse(AXGeometryValidation.isValidPosition(CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertTrue(AXGeometryValidation.isValidPosition(CGPoint(x: -20, y: 30)))
        XCTAssertFalse(AXGeometryValidation.isValidSize(CGSize(width: CGFloat.infinity, height: 50)))
        XCTAssertFalse(AXGeometryValidation.isValidSize(CGSize(width: 0, height: 50)))
        XCTAssertTrue(AXGeometryValidation.isValidSize(CGSize(width: 40, height: 50)))
    }

    func testWriteSelectionRequiresOnlyChangedAttributes() {
        let current = CGRect(x: 10, y: 10, width: 20, height: 25)
        let moved = CGRect(x: 30, y: 10, width: 20, height: 25)
        XCTAssertFalse(AXGeometryValidation.changes(from: current, to: moved).size)
        XCTAssertTrue(AXGeometryValidation.changes(from: current, to: moved).position)
        XCTAssertTrue(AXGeometryValidation.changes(from: current,
            to: CGRect(x: 10, y: 10, width: 30, height: 25)).size)
        XCTAssertFalse(AXGeometryValidation.changes(from: current, to: current).position)
    }

    func testFrameVerificationRejectsSizeClamping() {
        let requested = CGRect(x: 0, y: 0, width: 50, height: 60)
        XCTAssertTrue(AXGeometryValidation.matches(requested: requested,
                                                    actual: CGRect(x: 1, y: 0, width: 49, height: 60)))
        XCTAssertFalse(AXGeometryValidation.matches(requested: requested,
                                                     actual: CGRect(x: 0, y: 0, width: 40, height: 60)))
    }

    func testPositionVerificationRejectsClampingAndNonFiniteValues() {
        let requested = CGPoint(x: -199, y: 99)
        XCTAssertTrue(AXGeometryValidation.matches(requested: requested, actual: CGPoint(x: -198, y: 100)))
        XCTAssertFalse(AXGeometryValidation.matches(requested: requested, actual: CGPoint(x: 0, y: 99)))
        XCTAssertFalse(AXGeometryValidation.matches(requested: requested, actual: CGPoint(x: CGFloat.nan, y: 99)))
    }

    func testApplyOrderIsPositionFirstOnWidthGrowth() {
        let from = CGRect(x: 456, y: 47, width: 440, height: 1130)
        let to = CGRect(x: 0, y: 39, width: 1800, height: 1130)
        XCTAssertEqual(AXGeometryValidation.applyOrder(from: from, to: to), .positionFirst)
    }

    func testApplyOrderIsPositionFirstOnHeightGrowth() {
        let from = CGRect(x: 0, y: 39, width: 440, height: 400)
        let to = CGRect(x: 0, y: 39, width: 440, height: 1130)
        XCTAssertEqual(AXGeometryValidation.applyOrder(from: from, to: to), .positionFirst)
    }

    func testApplyOrderIsSizeFirstOnShrink() {
        let from = CGRect(x: 0, y: 39, width: 1800, height: 1130)
        let to = CGRect(x: 456, y: 47, width: 440, height: 553)
        XCTAssertEqual(AXGeometryValidation.applyOrder(from: from, to: to), .sizeFirst)
    }

    func testApplyOrderIsSizeFirstOnEqualSize() {
        let from = CGRect(x: 456, y: 47, width: 440, height: 553)
        XCTAssertEqual(AXGeometryValidation.applyOrder(from: from, to: from), .sizeFirst)
        let moved = CGRect(x: 0, y: 39, width: 440, height: 553)
        XCTAssertEqual(AXGeometryValidation.applyOrder(from: from, to: moved), .sizeFirst)
    }

    func testApplyOrderIsPositionFirstOnMixedGrowOneShrinkOne() {
        let from = CGRect(x: 456, y: 47, width: 440, height: 1130)
        let to = CGRect(x: 0, y: 39, width: 1800, height: 400)
        XCTAssertEqual(AXGeometryValidation.applyOrder(from: from, to: to), .positionFirst)
    }
}
