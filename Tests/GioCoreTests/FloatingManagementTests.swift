import XCTest
@testable import GioCore

final class FloatingManagementTests: XCTestCase {
    private func window(_ element: UInt64, mode: WindowMode = .tiled, reason: FloatReason? = nil) -> ManagedWindow {
        ManagedWindow(
            id: WindowID(pid: 10, elementID: element),
            pid: 10,
            application: "App",
            title: "t\(element)",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            mode: mode,
            floatReason: reason
        )
    }

    // MARK: Registry mode + reason

    func testFloatReasonDefaultsToNil() {
        XCTAssertNil(window(1).floatReason)
    }

    func testSetFloatingStoresReason() throws {
        let registry = WindowRegistry()
        try registry.register(window(1))
        try registry.setFloating(.notResizable, for: window(1).id)
        let stored = registry.find(window(1).id)
        XCTAssertEqual(stored?.mode, .floating)
        XCTAssertEqual(stored?.floatReason, .notResizable)
    }

    func testSetModeTiledClearsReason() throws {
        let registry = WindowRegistry()
        try registry.register(window(1, mode: .floating, reason: .dialog))
        try registry.setMode(.tiled, for: window(1).id)
        XCTAssertNil(registry.find(window(1).id)?.floatReason)
    }

    func testToggleFloatingSetsManualReasonAndClearsOnReturn() throws {
        let registry = WindowRegistry()
        try registry.register(window(1))
        try registry.toggleFloating(for: window(1).id)
        XCTAssertEqual(registry.find(window(1).id)?.floatReason, .manual)
        try registry.toggleFloating(for: window(1).id)
        XCTAssertNil(registry.find(window(1).id)?.floatReason)
    }

    func testSetFloatingUnknownThrows() {
        XCTAssertThrowsError(try WindowRegistry().setFloating(.rule, for: window(9).id))
    }

    // MARK: Tileability cache

    func testCacheProbesOncePerWindow() {
        var cache = TileabilityCache()
        var probes = 0
        let id = window(1).id
        XCTAssertEqual(cache.resolve(id, now: 0) { probes += 1; return .tileable }, .tileable)
        XCTAssertEqual(cache.resolve(id, now: 0) { probes += 1; return .notTileable }, .tileable)
        XCTAssertEqual(probes, 1)
    }

    func testCacheInvalidateOneReprobesOnlyThatWindow() {
        var cache = TileabilityCache()
        let a = window(1).id, b = window(2).id
        _ = cache.resolve(a, now: 0) { .tileable }
        _ = cache.resolve(b, now: 0) { .tileable }
        cache.invalidate(a)
        var probedA = false, probedB = false
        _ = cache.resolve(a, now: 0) { probedA = true; return .notTileable }
        _ = cache.resolve(b, now: 0) { probedB = true; return .notTileable }
        XCTAssertTrue(probedA)
        XCTAssertFalse(probedB)
    }

    func testCacheInvalidateAll() {
        var cache = TileabilityCache()
        let a = window(1).id
        _ = cache.resolve(a, now: 0) { .tileable }
        cache.invalidateAll()
        XCTAssertEqual(cache.resolve(a, now: 0) { .notTileable }, .notTileable)
    }

    func testCacheRetainDropsVanishedWindows() {
        var cache = TileabilityCache()
        let a = window(1).id, b = window(2).id
        _ = cache.resolve(a, now: 0) { .tileable }
        _ = cache.resolve(b, now: 0) { .tileable }
        cache.retain(keeping: [a])
        XCTAssertNil(cache.verdict(for: b))
        XCTAssertEqual(cache.verdict(for: a), true)
    }

    // MARK: Reflow-time tileability

    func testProbeFailureDemotesToFloatingNotResizable() throws {
        let registry = WindowRegistry()
        try registry.register(window(1))
        try registry.register(window(2))
        var cache = TileabilityCache()
        let modes = reconcileTileability(registry: registry, cache: &cache, now: 0) { $0.elementID == 1 ? .tileable : .notTileable }.modes
        XCTAssertEqual(modes[window(1).id], .tiled)
        XCTAssertEqual(modes[window(2).id], .floating)
        XCTAssertEqual(registry.find(window(2).id)?.floatReason, .notResizable)
    }

    func testRuleAndManualFloatsAreNeverProbedOrChanged() throws {
        let registry = WindowRegistry()
        try registry.register(window(1, mode: .floating, reason: .rule))
        var cache = TileabilityCache()
        var probed = false
        let modes = reconcileTileability(registry: registry, cache: &cache, now: 0) { _ in probed = true; return .tileable }.modes
        XCTAssertFalse(probed)
        XCTAssertEqual(modes[window(1).id], .floating)
        XCTAssertEqual(registry.find(window(1).id)?.floatReason, .rule)
    }

    /// FI-10: a window that yielded to its app stays floating whatever the
    /// probe says, until the user tiles it again (toggle-floating).
    func testAWindowThatYieldedToItsAppIsNeverProbedBackIntoTheLayout() throws {
        let registry = WindowRegistry()
        try registry.register(window(1))
        try registry.setFloating(.appControlled, for: window(1).id)
        var cache = TileabilityCache()
        var probed = false
        let modes = reconcileTileability(registry: registry, cache: &cache, now: 0) { _ in probed = true; return .tileable }.modes
        XCTAssertFalse(probed)
        XCTAssertEqual(modes[window(1).id], .floating)
        var session = CommandSession()
        try session.registry.register(registry.find(window(1).id)!)
        XCTAssertTrue(dispatch(.listWindows, session: &session).contains("mode=floating reason=appControlled"))
        XCTAssertEqual(try registry.toggleFloating(for: window(1).id), .tiled)
        XCTAssertNil(registry.find(window(1).id)?.floatReason)
    }

    func testNotResizableFloatPromotesBackWhenProbePasses() throws {
        let registry = WindowRegistry()
        try registry.register(window(1, mode: .floating, reason: .notResizable))
        var cache = TileabilityCache()
        let modes = reconcileTileability(registry: registry, cache: &cache, now: 0) { _ in .tileable }.modes
        XCTAssertEqual(modes[window(1).id], .tiled)
        XCTAssertEqual(registry.find(window(1).id)?.mode, .tiled)
        XCTAssertNil(registry.find(window(1).id)?.floatReason)
    }

    func testCachedVerdictSkipsProbeOnSecondReflow() throws {
        let registry = WindowRegistry()
        try registry.register(window(1))
        var cache = TileabilityCache()
        var probes = 0
        _ = reconcileTileability(registry: registry, cache: &cache, now: 0) { _ in probes += 1; return .tileable }
        _ = reconcileTileability(registry: registry, cache: &cache, now: 0) { _ in probes += 1; return .tileable }
        XCTAssertEqual(probes, 1)
    }

    // MARK: Exposure

    func testListWindowsShowsReasonForFloating() throws {
        var session = CommandSession()
        try session.registry.register(window(1))
        try session.registry.register(window(2, mode: .floating, reason: .notResizable))
        let output = dispatch(.listWindows, session: &session)
        XCTAssertTrue(output.contains("mode=floating reason=notResizable"))
        XCTAssertTrue(output.contains("mode=tiled"))
        XCTAssertFalse(output.contains("mode=tiled reason"))
    }

    func testStatusReportsModeCountsAndFloatingReasons() throws {
        var session = CommandSession()
        try session.registry.register(window(1))
        try session.registry.register(window(2, mode: .floating, reason: .notResizable))
        let json = try JSONSerialization.jsonObject(
            with: queryStatus(session: session).data(using: .utf8)!
        ) as! [String: Any]
        let modes = json["modes"] as! [String: Int]
        XCTAssertEqual(modes["tiled"], 1)
        XCTAssertEqual(modes["floating"], 1)
        let floating = json["floatingWindows"] as! [[String: String]]
        XCTAssertEqual(floating.count, 1)
        XCTAssertEqual(floating[0]["id"], "10:2")
        XCTAssertEqual(floating[0]["reason"], "notResizable")
        XCTAssertNotNil(json["workspace"])
    }
}
