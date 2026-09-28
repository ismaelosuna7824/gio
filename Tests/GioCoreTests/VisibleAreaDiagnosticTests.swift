import XCTest
@testable import GioCore

final class VisibleAreaDiagnosticTests: XCTestCase {
    func testSummaryReportsGeometryNumbersOnly() {
        let diagnostic = VisibleAreaDiagnostic(
            displayID: "1",
            displayBounds: CGRect(x: 0, y: 0, width: 1512, height: 944),
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            visibleFrame: CGRect(x: 0, y: 25, width: 1512, height: 871),
            cachedUsable: CGRect(x: 0, y: 48, width: 1512, height: 871))
        let line = diagnostic.summary()
        XCTAssertTrue(line.hasPrefix("VisibleArea display=1 "))
        XCTAssertTrue(line.contains("bounds=(0, 0, 1512, 944)"))
        XCTAssertTrue(line.contains("screen=(0, 0, 1512, 944)"))
        XCTAssertTrue(line.contains("visible=(0, 25, 1512, 871)"))
        XCTAssertTrue(line.contains("usable=(0, 48, 1512, 871)"))
        XCTAssertTrue(line.contains("cached=(0, 48, 1512, 871)"))
        XCTAssertTrue(line.contains("match=same"))
        XCTAssertFalse(line.contains("\n"))
    }

    func testSummaryFlagsCachedDrift() {
        let diagnostic = VisibleAreaDiagnostic(
            displayID: "1",
            displayBounds: CGRect(x: 0, y: 0, width: 1512, height: 944),
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            visibleFrame: CGRect(x: 0, y: 25, width: 1512, height: 871),
            cachedUsable: CGRect(x: 8, y: 608, width: 888, height: 553))
        let line = diagnostic.summary()
        XCTAssertTrue(line.contains("usable=(0, 48, 1512, 871)"))
        XCTAssertTrue(line.contains("cached=(8, 608, 888, 553)"))
        XCTAssertTrue(line.contains("match=drift"))
    }

    func testSummaryHandlesMissingCacheAndUnusableFrames() {
        let diagnostic = VisibleAreaDiagnostic(
            displayID: "2",
            displayBounds: CGRect(x: 1512, y: 0, width: 1200, height: 900),
            screenFrame: CGRect(x: 1512, y: 0, width: 1200, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let line = diagnostic.summary()
        XCTAssertTrue(line.contains("usable=nil"))
        XCTAssertTrue(line.contains("cached=nil"))
        XCTAssertTrue(line.contains("match=nocache"))
    }

    func testSummaryFormatsFractionalPoints() {
        let diagnostic = VisibleAreaDiagnostic(
            displayID: "1",
            displayBounds: CGRect(x: 0.5, y: 0, width: 1512, height: 944),
            screenFrame: CGRect(x: 0.5, y: 0, width: 1512, height: 944),
            visibleFrame: CGRect(x: 0.5, y: 0, width: 1512, height: 944))
        XCTAssertTrue(diagnostic.summary().contains("bounds=(0.5, 0, 1512, 944)"))
    }
}
