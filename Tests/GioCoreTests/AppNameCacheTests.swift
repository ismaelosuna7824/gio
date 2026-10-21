import XCTest
@testable import GioCore

/// PA-03: app names are resolved once per pid, never per write.
/// PA-15e: a name that could not be read is asked again, so per-app state
/// keyed by name (resize capability) never stays on the `pid<N>` placeholder.
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
        XCTAssertEqual(counter.count, 1)
    }

    func testAnUnreadableNameIsAskedAgainUntilItResolves() {
        let counter = Counter()
        let cache = AppNameCache { _ in counter.hit(); return counter.count < 2 ? nil : "Slack" }
        XCTAssertEqual(cache.display(20), "pid20")
        XCTAssertEqual(cache.display(20), "Slack")
        XCTAssertEqual(cache.display(20), "Slack")
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
