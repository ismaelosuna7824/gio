import XCTest
@testable import GioUI

/// FI-09: the launcher's presentation decisions (toggle, resign-key grace,
/// stale animation completions) without a window server.
final class LauncherLifecycleTests: XCTestCase {
    // MARK: Toggle derives from the panel, not a stale flag

    func testToggleShowsWhenPanelIsHidden() {
        let lifecycle = LauncherLifecycle()
        XCTAssertEqual(lifecycle.toggle(panelVisible: false), .show)
    }

    func testToggleDismissesAVisiblePresentedPanel() {
        var lifecycle = LauncherLifecycle()
        _ = lifecycle.beginShow(at: 10)
        XCTAssertEqual(lifecycle.toggle(panelVisible: true), .dismiss)
    }

    func testToggleShowsWhenLifecycleThinksShownButPanelIsGone() {
        var lifecycle = LauncherLifecycle()
        _ = lifecycle.beginShow(at: 10)
        XCTAssertEqual(lifecycle.toggle(panelVisible: false), .show)
    }

    func testToggleShowsWhenPanelIsOnScreenButNotPresented() {
        let lifecycle = LauncherLifecycle()
        XCTAssertEqual(lifecycle.toggle(panelVisible: true), .show)
    }

    func testToggleShowsAgainWhileFadingOut() {
        var lifecycle = LauncherLifecycle()
        _ = lifecycle.beginShow(at: 10)
        XCTAssertNotNil(lifecycle.beginDismiss())
        XCTAssertEqual(lifecycle.toggle(panelVisible: true), .show)
    }

    // MARK: Resign key

    func testResignWithinGraceReclaimsKey() {
        var lifecycle = LauncherLifecycle()
        _ = lifecycle.beginShow(at: 10)
        XCTAssertEqual(lifecycle.resignDecision(now: 10.1), .reclaimKey)
        XCTAssertEqual(lifecycle.resignDecision(now: 10 + LauncherLifecycle.resignGrace - 0.001), .reclaimKey)
    }

    func testResignAfterGraceDismisses() {
        var lifecycle = LauncherLifecycle()
        _ = lifecycle.beginShow(at: 10)
        XCTAssertEqual(lifecycle.resignDecision(now: 10 + LauncherLifecycle.resignGrace), .dismiss)
        XCTAssertEqual(lifecycle.resignDecision(now: 42), .dismiss)
    }

    func testResignIsIgnoredWhenHiddenOrDismissing() {
        var lifecycle = LauncherLifecycle()
        XCTAssertEqual(lifecycle.resignDecision(now: 10), .ignore)
        _ = lifecycle.beginShow(at: 10)
        _ = lifecycle.beginDismiss()
        XCTAssertEqual(lifecycle.resignDecision(now: 11), .ignore)
    }

    func testGraceIsQuarterSecond() {
        XCTAssertEqual(LauncherLifecycle.resignGrace, 0.25, accuracy: 0.0001)
    }

    // MARK: Animation completions

    func testDismissCompletionOrdersOutWhenCurrent() {
        var lifecycle = LauncherLifecycle()
        _ = lifecycle.beginShow(at: 10)
        let token = try! XCTUnwrap(lifecycle.beginDismiss())
        XCTAssertTrue(lifecycle.finishDismiss(token))
        XCTAssertFalse(lifecycle.isPresented)
        XCTAssertEqual(lifecycle.toggle(panelVisible: false), .show)
    }

    func testDismissIsSingleShot() {
        var lifecycle = LauncherLifecycle()
        XCTAssertNil(lifecycle.beginDismiss(), "nothing presented")
        _ = lifecycle.beginShow(at: 10)
        XCTAssertNotNil(lifecycle.beginDismiss())
        XCTAssertNil(lifecycle.beginDismiss(), "already fading out")
    }

    func testStaleDismissCompletionDoesNotHideARepresentedPanel() {
        var lifecycle = LauncherLifecycle()
        _ = lifecycle.beginShow(at: 10)
        let fadeOut = try! XCTUnwrap(lifecycle.beginDismiss())
        let reshow = lifecycle.beginShow(at: 10.05)
        XCTAssertFalse(lifecycle.finishDismiss(fadeOut), "old fade-out must not order out the new panel")
        XCTAssertTrue(lifecycle.isPresented)
        XCTAssertTrue(lifecycle.finishAppear(reshow))
    }

    func testAppearCompletionAppliesOnlyToCurrentShow() {
        var lifecycle = LauncherLifecycle()
        let first = lifecycle.beginShow(at: 10)
        XCTAssertTrue(lifecycle.finishAppear(first))
        XCTAssertTrue(lifecycle.finishAppear(first), "idempotent: safety net and completion may both run")
        let second = lifecycle.beginShow(at: 11)
        XCTAssertFalse(lifecycle.finishAppear(first))
        XCTAssertTrue(lifecycle.finishAppear(second))
        _ = lifecycle.beginDismiss()
        XCTAssertFalse(lifecycle.finishAppear(second), "fading out: do not force it opaque")
    }

    func testAppearPlanFadesOnlyWithReduceMotion() {
        let reduced = LauncherLifecycle.appearPlan(reduceMotion: true)
        XCTAssertEqual(reduced.offset, 0)
        XCTAssertEqual(reduced.duration, 0.12, accuracy: 0.0001)
        let full = LauncherLifecycle.appearPlan(reduceMotion: false)
        XCTAssertEqual(full.offset, 8)
        XCTAssertEqual(full.duration, 0.18, accuracy: 0.0001)
    }

    func testAppearSafetyNetFiresAfterTheAnimation() {
        for reduceMotion in [true, false] {
            let plan = LauncherLifecycle.appearPlan(reduceMotion: reduceMotion)
            XCTAssertGreaterThan(plan.safetyDeadline, plan.duration)
            XCTAssertLessThanOrEqual(plan.safetyDeadline, plan.duration + 0.2)
        }
    }

    // MARK: Log vocabulary (no titles)

    func testLogReasonsAndSources() {
        XCTAssertEqual(LauncherSummonSource.hotkey.rawValue, "hotkey")
        XCTAssertEqual(LauncherSummonSource.menu.rawValue, "menu")
        XCTAssertEqual(
            [LauncherDismissReason.escape, .toggle, .resignKey, .action].map(\.rawValue),
            ["escape", "toggle", "resignKey", "action"]
        )
    }
}
