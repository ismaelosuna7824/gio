import CoreGraphics
import XCTest
import GioCore
@testable import GioMacOS

/// FI-05: the WindowServer list is parsed into Cocoa-space `ServerWindow`s;
/// only layer-0 windows with a pid and bounds are kept, and no title key is
/// ever read for them (SM-17: only snapshot candidates carry the window name).
final class WindowServerSnapshotTests: XCTestCase {
    private func entry(pid: Int, layer: Int, x: Double, y: Double, w: Double, h: Double) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
        ]
    }

    func testKeepsLayerZeroWindowsAndFlipsToCocoa() {
        let windows = parseWindowServerEntries(
            [entry(pid: 5, layer: 0, x: 10, y: 100, w: 600, h: 400)], displayHeight: 1000
        )
        XCTAssertEqual(windows, [ServerWindow(pid: 5, bounds: CGRect(x: 10, y: 500, width: 600, height: 400))])
    }

    func testDropsOverlaysAndMalformedEntries() {
        let windows = parseWindowServerEntries(
            [
                entry(pid: 5, layer: 25, x: 0, y: 0, w: 100, h: 20),
                [kCGWindowLayer as String: 0],
                [kCGWindowOwnerPID as String: 7, kCGWindowLayer as String: 0],
            ],
            displayHeight: 1000
        )
        XCTAssertEqual(windows, [])
    }

    func testCandidatesCarryWindowNumberAndFilterByPid() {
        var kept = entry(pid: 5, layer: 0, x: 10, y: 100, w: 600, h: 400)
        kept[kCGWindowNumber as String] = 42
        var other = entry(pid: 6, layer: 0, x: 0, y: 0, w: 100, h: 100)
        other[kCGWindowNumber as String] = 43
        let noNumber = entry(pid: 5, layer: 0, x: 0, y: 0, w: 100, h: 100)
        let candidates = parseSnapshotCandidates(
            [kept, other, noNumber], pids: [5], displayHeight: 1000
        )
        XCTAssertEqual(
            candidates, [SnapshotCandidate(windowID: 42, pid: 5, frame: CGRect(x: 10, y: 500, width: 600, height: 400))]
        )
    }

    /// SM-17: the window name (`kCGWindowName`, listed with Screen
    /// Recording) rides on the candidate for the title tie-break; absent or
    /// empty, the candidate has none. Synthetic names only.
    func testCandidatesCarryTheWindowNameOnlyWhenListed() {
        var named = entry(pid: 5, layer: 0, x: 10, y: 100, w: 600, h: 400)
        named[kCGWindowNumber as String] = 42
        named[kCGWindowName as String] = "T-fixture"
        var unnamed = entry(pid: 5, layer: 0, x: 10, y: 100, w: 600, h: 400)
        unnamed[kCGWindowNumber as String] = 43
        var empty = entry(pid: 5, layer: 0, x: 10, y: 100, w: 600, h: 400)
        empty[kCGWindowNumber as String] = 44
        empty[kCGWindowName as String] = ""
        let candidates = parseSnapshotCandidates([named, unnamed, empty], pids: [5], displayHeight: 1000)
        XCTAssertEqual(candidates.map(\.windowID), [42, 43, 44])
        XCTAssertEqual(candidates.map { $0.title != nil }, [true, false, false])
        XCTAssertTrue(candidates[0].title == "T-fixture", "the listed name, unchanged")
    }

    /// SM-20: the on-screen list is documented front to back; the stacking
    /// keeps that order for the layer-0 windows of the asked apps.
    func testStackingKeepsTheListOrderOfLayerZeroWindowsOfThePids() {
        func numbered(_ number: Int, pid: Int, layer: Int = 0) -> [String: Any] {
            var item = entry(pid: pid, layer: layer, x: 0, y: 0, w: 100, h: 100)
            item[kCGWindowNumber as String] = number
            return item
        }
        let entries = [
            numbered(30, pid: 5), numbered(31, pid: 6), numbered(32, pid: 5, layer: 25), numbered(33, pid: 7),
            numbered(34, pid: 5), entry(pid: 5, layer: 0, x: 0, y: 0, w: 1, h: 1),
        ]
        XCTAssertEqual(parseWindowServerStacking(entries, pids: [5, 7]), [30, 33, 34])
    }

    /// SM-10: Gio's own panels (ring, dim, overlay) sit above layer 0; a
    /// backdrop capture needs their ids, whatever the layer, to exclude them.
    func testOwnWindowIDsKeepEveryLayerOfOnePid() {
        var ring = entry(pid: 9, layer: 25, x: 0, y: 0, w: 100, h: 20)
        ring[kCGWindowNumber as String] = 70
        var main = entry(pid: 9, layer: 0, x: 0, y: 0, w: 100, h: 20)
        main[kCGWindowNumber as String] = 71
        var other = entry(pid: 6, layer: 0, x: 0, y: 0, w: 100, h: 100)
        other[kCGWindowNumber as String] = 43
        let noNumber = entry(pid: 9, layer: 0, x: 0, y: 0, w: 100, h: 100)
        XCTAssertEqual(parseWindowServerWindowIDs([ring, main, other, noNumber], pid: 9), [70, 71])
    }
}
