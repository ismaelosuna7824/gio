import Foundation
@testable import GioUI
import XCTest

/// PF-01: the launcher's app list is scanned in the background; app launch
/// notifications refresh it, debounced, and never two scans at once.
final class LauncherCatalogRefreshTests: XCTestCase {
    func testABurstOfRequestsFiresOnlyTheLastOne() {
        var refresh = LauncherCatalogRefresh()
        let first = refresh.request()
        let second = refresh.request()
        let last = refresh.request()

        XCTAssertFalse(refresh.fire(first, at: 1))
        XCTAssertFalse(refresh.fire(second, at: 1))
        XCTAssertTrue(refresh.fire(last, at: 1), "one scan per burst")
        XCTAssertTrue(refresh.isScanning)
    }

    func testARequestDuringAScanRunsOneMoreScanAfterIt() {
        var refresh = LauncherCatalogRefresh()
        XCTAssertTrue(refresh.fire(refresh.request(), at: 0))
        let during = refresh.request()
        XCTAssertFalse(refresh.fire(during, at: 0.6), "never two scans at once")

        XCTAssertTrue(refresh.finishScan(at: 1), "the deferred request scans again")
        XCTAssertFalse(refresh.finishScan(at: 2))
        XCTAssertFalse(refresh.isScanning)
    }

    func testStartupScanNeedsNoRequest() {
        var refresh = LauncherCatalogRefresh()
        XCTAssertTrue(refresh.isStale(at: 0), "never scanned")
        XCTAssertTrue(refresh.beginScan())
        XCTAssertFalse(refresh.beginScan(), "already scanning")
        XCTAssertFalse(refresh.finishScan(at: 5))
        XCTAssertFalse(refresh.isStale(at: 5 + LauncherCatalogRefresh.staleAfter - 1))
        XCTAssertTrue(refresh.isStale(at: 5 + LauncherCatalogRefresh.staleAfter + 1))
    }

    func testDebounceIsShort() {
        XCTAssertLessThanOrEqual(LauncherCatalogRefresh.debounce, 1)
        XCTAssertGreaterThan(LauncherCatalogRefresh.debounce, 0)
    }

    /// PF-T (2026-10-15 profile): every app launch redrew the icon of every
    /// installed app (8 % of Gio's CPU while in use). A refresh draws only
    /// the bundles that are new or changed since their icon was drawn.
    func testARefreshDrawsOnlyNewOrChangedIcons() {
        let known = ["/A.app": 10.0, "/B.app": 20.0, "/Gone.app": 5.0]
        let found = ["/A.app": 10.0, "/B.app": 25.0, "/New.app": 30.0]
        XCTAssertEqual(launcherIconsToDraw(found: found, drawn: known), ["/B.app", "/New.app"])
        XCTAssertEqual(launcherIconsToDraw(found: found, drawn: found), [])
        XCTAssertEqual(launcherIconsToDraw(found: found, drawn: [:]), ["/A.app", "/B.app", "/New.app"])
    }
}
