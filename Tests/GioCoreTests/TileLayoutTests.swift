import Foundation
import XCTest
@testable import GioCore

final class TileLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 10, y: 20, width: 100, height: 80)

    func testEmptyAndSingle() throws {
        XCTAssertEqual(try TileLayout.plan(windows: [], in: bounds), [])
        XCTAssertEqual(try TileLayout.plan(windows: ["a"], in: bounds, outerGap: 5), [
            TileTarget(window: "a", frame: CGRect(x: 15, y: 25, width: 90, height: 70))
        ])
    }

    func testTwoThreeAndFourBalancedInInputOrder() throws {
        XCTAssertEqual(try TileLayout.plan(windows: ["z", "a"], in: bounds), [
            TileTarget(window: "z", frame: CGRect(x: 10, y: 20, width: 50, height: 80)),
            TileTarget(window: "a", frame: CGRect(x: 60, y: 20, width: 50, height: 80))
        ])
        let three = try TileLayout.plan(windows: ["z", "a", "m"], in: bounds)
        XCTAssertEqual(three.map(\.window), ["z", "a", "m"])
        XCTAssertEqual(three.map(\.frame), [
            CGRect(x: 10, y: 20, width: 50, height: 40),
            CGRect(x: 10, y: 60, width: 50, height: 40),
            CGRect(x: 60, y: 20, width: 50, height: 80)
        ])
        let four = try TileLayout.plan(windows: ["z", "a", "m", "b"], in: bounds)
        XCTAssertEqual(four.map(\.window), ["z", "a", "m", "b"])
        XCTAssertEqual(four.map(\.frame), [
            CGRect(x: 10, y: 20, width: 50, height: 40),
            CGRect(x: 10, y: 60, width: 50, height: 40),
            CGRect(x: 60, y: 20, width: 50, height: 40),
            CGRect(x: 60, y: 60, width: 50, height: 40)
        ])
        XCTAssertEqual(try TileLayout.plan(windows: ["z", "a", "m", "b"], in: bounds), four)
    }

    func testGapsAndIndependentDisplayRectangles() throws {
        let left = try TileLayout.plan(windows: ["a", "b"], in: bounds, outerGap: 5, innerGap: 10)
        XCTAssertEqual(left.map(\.frame), [
            CGRect(x: 15, y: 25, width: 40, height: 70),
            CGRect(x: 65, y: 25, width: 40, height: 70)
        ])
        let right = try TileLayout.plan(windows: ["a", "b"],
                                        in: CGRect(x: 300, y: 100, width: 80, height: 120),
                                        outerGap: 5, innerGap: 10)
        XCTAssertEqual(right.map(\.frame), [
            CGRect(x: 305, y: 105, width: 70, height: 50),
            CGRect(x: 305, y: 165, width: 70, height: 50)
        ])
        XCTAssertEqual(try TileLayout.plan(windows: ["a", "b"], in: bounds, outerGap: 5, innerGap: 10), left)
    }

    func testPositiveGapsMustSurviveCoordinateRounding() throws {
        let subULP = CGFloat.leastNonzeroMagnitude
        XCTAssertThrowsError(try TileLayout.plan(windows: ["a", "b"], in: bounds, innerGap: subULP)) {
            XCTAssertEqual($0 as? TileLayoutError, .insufficientSpace)
        }
        XCTAssertThrowsError(try TileLayout.plan(windows: ["a"], in: bounds, outerGap: subULP)) {
            XCTAssertEqual($0 as? TileLayoutError, .insufficientSpace)
        }
        let ordinary = try TileLayout.plan(windows: ["a", "b"], in: bounds, outerGap: 5, innerGap: 10)
        XCTAssertGreaterThan(ordinary[0].frame.minX, bounds.minX)
        XCTAssertLessThan(ordinary[1].frame.maxX, bounds.maxX)
        XCTAssertGreaterThan(ordinary[1].frame.minX, ordinary[0].frame.maxX)
    }

    func testInvalidInputs() throws {
        XCTAssertThrowsError(try TileLayout.plan(windows: ["a", "a"], in: bounds)) {
            XCTAssertEqual($0 as? TileLayoutError, .duplicateWindow("a"))
        }
        for gap in [CGFloat(-1), .infinity, .nan] {
            XCTAssertThrowsError(try TileLayout.plan(windows: ["a"], in: bounds, innerGap: gap)) {
                XCTAssertEqual($0 as? TileLayoutError, .invalidGap)
            }
            XCTAssertThrowsError(try TileLayout.plan(windows: [], in: bounds, outerGap: gap))
        }
        for rect in [CGRect(x: 0, y: 0, width: 0, height: 10),
                     CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10),
                     CGRect(x: 0, y: 0, width: 10, height: CGFloat.nan)] {
            XCTAssertThrowsError(try TileLayout.plan(windows: ["a"], in: rect)) {
                XCTAssertEqual($0 as? TileLayoutError, .invalidBounds)
            }
        }
        XCTAssertThrowsError(try TileLayout.plan(windows: ["a"], in: bounds, outerGap: 40)) {
            XCTAssertEqual($0 as? TileLayoutError, .insufficientSpace)
        }
        XCTAssertThrowsError(try TileLayout.plan(windows: ["a", "b"], in: bounds, innerGap: 100)) {
            XCTAssertEqual($0 as? TileLayoutError, .insufficientSpace)
        }
        XCTAssertThrowsError(try TileLayout.plan(windows: ["a", "b", "c"], in: bounds, innerGap: 80)) {
            XCTAssertEqual($0 as? TileLayoutError, .insufficientSpace)
        }
        let tiny = CGRect(x: 0, y: 0, width: CGFloat.leastNonzeroMagnitude, height: CGFloat.leastNonzeroMagnitude)
        XCTAssertEqual(try TileLayout.plan(windows: ["a"], in: tiny).count, 1)
        XCTAssertThrowsError(try TileLayout.plan(windows: ["a", "b"], in: tiny)) {
            XCTAssertEqual($0 as? TileLayoutError, .insufficientSpace)
        }
    }

    func testOverflowingEdgesAreRejectedBeforeProducingTargets() throws {
        let huge = CGFloat.greatestFiniteMagnitude
        let overflow = CGRect(x: huge, y: 0, width: huge, height: 10)
        XCTAssertThrowsError(try TileLayout.plan(windows: ["a"], in: overflow)) {
            XCTAssertEqual($0 as? TileLayoutError, .invalidBounds)
        }
        XCTAssertThrowsError(try TileLayout.plan(windows: [], in: overflow)) {
            XCTAssertEqual($0 as? TileLayoutError, .invalidBounds)
        }
        // Insetting can overflow an otherwise finite rectangle's new origin.
        let insetOverflow = CGRect(x: huge, y: 0, width: 1, height: 10)
        XCTAssertThrowsError(try TileLayout.plan(windows: ["a"], in: insetOverflow, outerGap: 1))
    }
}
