import XCTest
@testable import GioCore

/// PA-03: app names are resolved once per pid, never per write.
final class AppNameCacheTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        func hit() { lock.withLock { calls += 1 } }
    }

    func testResolvesOncePerPid() {
        let counter = Counter()
        let cache = AppNameCache { pid in counter.hit(); return pid == 10 ? "Code" : nil }
        XCTAssertEqual(cache.display(10), "Code")
        XCTAssertEqual(cache.display(10), "Code")
        XCTAssertEqual(cache.display(20), "pid20")
        XCTAssertEqual(cache.display(20), "pid20")
        XCTAssertEqual(counter.count, 2)
    }

    func testForgetResolvesAgainForAReusedPid() {
        let counter = Counter()
        let cache = AppNameCache { _ in counter.hit(); return "App\(counter.count)" }
        XCTAssertEqual(cache.display(10), "App1")
        cache.forget(10)
        XCTAssertEqual(cache.display(10), "App2")
    }
}
