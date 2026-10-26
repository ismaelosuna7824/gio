import XCTest
@testable import GioCore

final class TileabilityProbeTests: XCTestCase {
    private let cannotComplete = -25204
    private let start: TimeInterval = 100

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func registry(_ windows: [(UInt64, WindowMode, FloatReason?)]) throws -> WindowRegistry {
        let registry = WindowRegistry()
        for (element, mode, reason) in windows {
            try registry.register(ManagedWindow(
                id: id(element), pid: 10, application: "App", title: "secret title",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                mode: mode, floatReason: reason
            ))
        }
        return registry
    }

    func testUndeterminedProbeKeepsATiledWindowTiledAndCachesNothing() throws {
        let registry = try registry([(1, .tiled, nil)])
        var cache = TileabilityCache()
        let undetermined = TileabilityProbe.undetermined(status: cannotComplete)
        let modes = reconcileTileability(registry: registry, cache: &cache, now: start) { _ in undetermined }.modes
        XCTAssertEqual(modes[id(1)], .tiled)
        XCTAssertEqual(registry.find(id(1))?.mode, .tiled)
        XCTAssertNil(cache.verdict(for: id(1)))
    }

    func testUndeterminedProbeKeepsANotResizableFloatFloating() throws {
        let registry = try registry([(1, .floating, .notResizable)])
        var cache = TileabilityCache()
        let undetermined = TileabilityProbe.undetermined(status: cannotComplete)
        let modes = reconcileTileability(registry: registry, cache: &cache, now: start) { _ in undetermined }.modes
        XCTAssertEqual(modes[id(1)], .floating)
        XCTAssertEqual(registry.find(id(1))?.floatReason, .notResizable)
    }

    func testUndeterminedWindowIsRetriedOnlyAfterTheRetryInterval() throws {
        let registry = try registry([(1, .tiled, nil)])
        var cache = TileabilityCache()
        var probes = 0
        _ = reconcileTileability(registry: registry, cache: &cache, now: start) { _ in
            probes += 1
            return .undetermined(status: self.cannotComplete)
        }
        let beforeDeadline = start + TileabilityCache.retryInterval - 0.1
        let early = reconcileTileability(registry: registry, cache: &cache, now: beforeDeadline) { _ in
            probes += 1
            return .notTileable
        }
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(early.modes[id(1)], .tiled)
        let atDeadline = start + TileabilityCache.retryInterval
        let retried = reconcileTileability(registry: registry, cache: &cache, now: atDeadline) { _ in
            probes += 1
            return .notTileable
        }
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(retried.modes[id(1)], .floating)
        XCTAssertEqual(registry.find(id(1))?.floatReason, .notResizable)
    }

    func testANotResizableFloatRejoinsOnceItsAppAnswersAgain() throws {
        let registry = try registry([(1, .floating, .notResizable)])
        var cache = TileabilityCache()
        _ = reconcileTileability(registry: registry, cache: &cache, now: start) { _ in
            .undetermined(status: self.cannotComplete)
        }
        let later = start + TileabilityCache.retryInterval
        let modes = reconcileTileability(registry: registry, cache: &cache, now: later) { _ in .tileable }.modes
        XCTAssertEqual(modes[id(1)], .tiled)
        XCTAssertNil(registry.find(id(1))?.floatReason)
    }

    func testInvalidateClearsTheRetryDeadline() {
        var cache = TileabilityCache()
        _ = cache.resolve(id(1), now: start) { .undetermined(status: cannotComplete) }
        cache.invalidate(id(1))
        var probed = false
        let resolution = cache.resolve(id(1), now: start) { probed = true; return .tileable }
        XCTAssertTrue(probed)
        XCTAssertEqual(resolution, .tileable)
    }

    func testInvalidateAllAndRetainClearRetryDeadlines() {
        var cache = TileabilityCache()
        _ = cache.resolve(id(1), now: start) { .undetermined(status: cannotComplete) }
        _ = cache.resolve(id(2), now: start) { .undetermined(status: cannotComplete) }
        cache.retain(keeping: [id(1)])
        XCTAssertEqual(cache.resolve(id(2), now: start) { .tileable }, .tileable)
        cache.invalidateAll()
        XCTAssertEqual(cache.resolve(id(1), now: start) { .notTileable }, .notTileable)
    }

    func testPendingRetryResolvesWithoutProbing() {
        var cache = TileabilityCache()
        let first = cache.resolve(id(1), now: start) { .undetermined(status: cannotComplete) }
        XCTAssertEqual(first, .undetermined(status: cannotComplete))
        var probed = false
        let second = cache.resolve(id(1), now: start + 1) { probed = true; return .tileable }
        XCTAssertFalse(probed)
        XCTAssertEqual(second, .retryPending)
    }

    func testDemotionIsReportedWithItsLogLine() throws {
        let registry = try registry([(1, .tiled, nil), (2, .tiled, nil)])
        var cache = TileabilityCache()
        let result = reconcileTileability(registry: registry, cache: &cache, now: start) {
            $0 == self.id(1) ? .tileable : .notTileable
        }
        XCTAssertEqual(result.changes.map(\.logLine), [
            "window mode id=10:2 app=App from=tiled to=floating reason=notResizable",
        ])
        XCTAssertEqual(result.undetermined, [])
    }

    func testPromotionIsReportedWithItsLogLine() throws {
        let registry = try registry([(1, .floating, .notResizable)])
        var cache = TileabilityCache()
        let result = reconcileTileability(registry: registry, cache: &cache, now: start) { _ in .tileable }
        XCTAssertEqual(result.changes.map(\.logLine), [
            "window mode id=10:1 app=App from=floating to=tiled reason=resizable",
        ])
    }

    func testUnchangedModesReportNothing() throws {
        let registry = try registry([(1, .tiled, nil), (2, .floating, .notResizable), (3, .floating, .rule)])
        var cache = TileabilityCache()
        let result = reconcileTileability(registry: registry, cache: &cache, now: start) {
            $0 == self.id(1) ? .tileable : .notTileable
        }
        XCTAssertEqual(result.changes, [])
        XCTAssertEqual(result.modes[id(3)], .floating)
    }

    func testUndeterminedProbeIsReportedOncePerRetryInterval() throws {
        let registry = try registry([(1, .tiled, nil)])
        var cache = TileabilityCache()
        let undetermined = TileabilityProbe.undetermined(status: cannotComplete)
        let first = reconcileTileability(registry: registry, cache: &cache, now: start) { _ in undetermined }
        let again = reconcileTileability(registry: registry, cache: &cache, now: start + 1) { _ in undetermined }
        XCTAssertEqual(first.undetermined.map(\.logLine), [
            "window probe undetermined id=10:1 app=App axerror=-25204",
        ])
        XCTAssertEqual(first.changes, [])
        XCTAssertEqual(again.undetermined, [])
    }

    func testLogLinesNeverCarryTheWindowTitle() throws {
        let registry = try registry([(1, .tiled, nil), (2, .tiled, nil)])
        var cache = TileabilityCache()
        let result = reconcileTileability(registry: registry, cache: &cache, now: start) {
            $0 == self.id(1) ? .undetermined(status: self.cannotComplete) : .notTileable
        }
        let lines = result.changes.map(\.logLine) + result.undetermined.map(\.logLine)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.contains { $0.contains("secret") })
    }
}
