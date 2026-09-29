import XCTest
@testable import GioCore

/// PA-04: the inactive-workspace parking plan is recomputed only when one of
/// its inputs changed, or when explicitly invalidated.
final class PlanMemoTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private struct Key: Equatable {
        var hidden: [WindowID]
        var display: CGRect
    }

    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)

    func testSameKeyReusesTheCachedValue() {
        var memo = PlanMemo<Key, Int>()
        var computes = 0
        let key = Key(hidden: [id(1)], display: display)
        XCTAssertEqual(memo.value(for: key) { computes += 1; return 7 }, 7)
        XCTAssertEqual(memo.value(for: key) { computes += 1; return 8 }, 7)
        XCTAssertEqual(computes, 1)
    }

    func testMembershipChangeRecomputes() {
        var memo = PlanMemo<Key, Int>()
        var computes = 0
        _ = memo.value(for: Key(hidden: [id(1)], display: display)) { computes += 1; return 1 }
        _ = memo.value(for: Key(hidden: [id(1), id(2)], display: display)) { computes += 1; return 2 }
        XCTAssertEqual(computes, 2)
    }

    func testWindowRemovalRecomputes() {
        var memo = PlanMemo<Key, Int>()
        var computes = 0
        _ = memo.value(for: Key(hidden: [id(1), id(2)], display: display)) { computes += 1; return 1 }
        _ = memo.value(for: Key(hidden: [id(1)], display: display)) { computes += 1; return 2 }
        XCTAssertEqual(computes, 2)
    }

    func testDisplayChangeRecomputes() {
        var memo = PlanMemo<Key, Int>()
        var computes = 0
        _ = memo.value(for: Key(hidden: [id(1)], display: display)) { computes += 1; return 1 }
        _ = memo.value(for: Key(hidden: [id(1)], display: CGRect(x: 0, y: 0, width: 1440, height: 900))) {
            computes += 1
            return 2
        }
        XCTAssertEqual(computes, 2)
    }

    func testExplicitInvalidationRecomputesEvenWithTheSameKey() {
        var memo = PlanMemo<Key, Int>()
        var computes = 0
        let key = Key(hidden: [id(1)], display: display)
        _ = memo.value(for: key) { computes += 1; return 1 }
        memo.invalidate()
        XCTAssertEqual(memo.value(for: key) { computes += 1; return 2 }, 2)
        XCTAssertEqual(computes, 2)
    }
}
