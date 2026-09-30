import XCTest
@testable import GioCore

/// Native zoom for maximize (`[animations] native-zoom`): the app's own zoom
/// animates in-process, so Gio presses it instead of writing a new size.
/// Everything decidable lives here as pure logic; the host only wires it.
final class NativeZoomTests: XCTestCase {
    private func id(_ pid: pid_t, _ element: UInt64 = 1) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private let visible = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private let target = CGRect(x: 8, y: 8, width: 1584, height: 884)

    // MARK: request + eligibility

    private func workspace(columns: [[WindowID]], focusedColumn: Int = 0, saved: ColumnWidthSpec? = nil) -> Workspace {
        var workspace = Workspace(id: WorkspaceID(1))
        workspace.columns = columns.enumerated().map { index, windows in
            Column(id: ColumnID(UInt64(index + 1)), width: 0, windows: windows, widthSpec: .proportion(0.5))
        }
        workspace.focusedColumn = focusedColumn
        if let saved {
            workspace.columns[focusedColumn].savedWidthSpec = saved
        }
        return workspace
    }

    func testRequestForASingleWindowColumnIsAMaximize() {
        let request = nativeZoomRequest(in: workspace(columns: [[id(1)], [id(2)]]), nativeMaximized: { _ in false })
        XCTAssertEqual(request, NativeZoomRequest(id: id(1), action: .maximize, columnWindowCount: 1, wasNativeMaximized: false))
    }

    func testRequestOnAMaximizedColumnIsARestoreAndCarriesTheNativeFlag() {
        let maximized = workspace(columns: [[id(1)]], saved: .proportion(0.5))
        XCTAssertEqual(
            nativeZoomRequest(in: maximized, nativeMaximized: { $0 == self.id(1) }),
            NativeZoomRequest(id: id(1), action: .restore, columnWindowCount: 1, wasNativeMaximized: true)
        )
        XCTAssertEqual(
            nativeZoomRequest(in: maximized, nativeMaximized: { _ in false })?.wasNativeMaximized, false
        )
    }

    func testNoRequestWithoutAFocusedWindow() {
        XCTAssertNil(nativeZoomRequest(in: Workspace(id: WorkspaceID(1)), nativeMaximized: { _ in false }))
    }

    func testStackedColumnCountsItsWindows() {
        let request = nativeZoomRequest(in: workspace(columns: [[id(1), id(2)]]), nativeMaximized: { _ in false })
        XCTAssertEqual(request?.columnWindowCount, 2)
    }

    private func request(
        _ action: NativeZoomAction = .maximize, count: Int = 1, native: Bool = false
    ) -> NativeZoomRequest {
        NativeZoomRequest(id: id(1), action: action, columnWindowCount: count, wasNativeMaximized: native)
    }

    func testEligibleMaximizeNeedsConfigSingleWindowGrowthAndAZoomButton() {
        XCTAssertEqual(
            nativeZoomEligibility(request(), enabled: true, grows: true, zoomAvailable: true), .eligible
        )
        XCTAssertEqual(
            nativeZoomEligibility(request(), enabled: false, grows: true, zoomAvailable: true),
            .ineligible(.disabled)
        )
        XCTAssertEqual(
            nativeZoomEligibility(request(count: 2), enabled: true, grows: true, zoomAvailable: true),
            .ineligible(.stackedColumn)
        )
        XCTAssertEqual(
            nativeZoomEligibility(request(), enabled: true, grows: false, zoomAvailable: true),
            .ineligible(.notGrowing)
        )
        XCTAssertEqual(
            nativeZoomEligibility(request(), enabled: true, grows: true, zoomAvailable: false),
            .ineligible(.zoomUnavailable)
        )
    }

    func testEligibilityReportsTheFirstFailingRule() {
        XCTAssertEqual(
            nativeZoomEligibility(request(count: 3), enabled: false, grows: false, zoomAvailable: false),
            .ineligible(.disabled)
        )
        XCTAssertEqual(
            nativeZoomEligibility(request(count: 3), enabled: true, grows: false, zoomAvailable: false),
            .ineligible(.stackedColumn)
        )
    }

    func testRestoreOnlyPressesZoomWhenTheMaximizeWasNative() {
        XCTAssertEqual(
            nativeZoomEligibility(request(.restore, native: true), enabled: true, grows: false, zoomAvailable: true),
            .eligible
        )
        XCTAssertEqual(
            nativeZoomEligibility(request(.restore, native: false), enabled: true, grows: false, zoomAvailable: true),
            .ineligible(.notNativeMaximized)
        )
        XCTAssertEqual(
            nativeZoomEligibility(request(.restore, count: 2, native: true), enabled: true, grows: false, zoomAvailable: true),
            .ineligible(.stackedColumn)
        )
        XCTAssertEqual(
            nativeZoomEligibility(request(.restore, native: true), enabled: false, grows: false, zoomAvailable: true),
            .ineligible(.disabled)
        )
        XCTAssertEqual(
            nativeZoomEligibility(request(.restore, native: true), enabled: true, grows: false, zoomAvailable: false),
            .ineligible(.zoomUnavailable)
        )
    }

    func testGrowthInEitherDimensionCountsAndRoundingDoesNot() {
        let base = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertTrue(nativeZoomGrows(from: base, to: CGRect(x: 0, y: 0, width: 1200, height: 600)))
        XCTAssertTrue(nativeZoomGrows(from: base, to: CGRect(x: 0, y: 0, width: 800, height: 700)))
        XCTAssertFalse(nativeZoomGrows(from: base, to: CGRect(x: 0, y: 0, width: 800.5, height: 600)))
        XCTAssertFalse(nativeZoomGrows(from: base, to: CGRect(x: 0, y: 0, width: 400, height: 600)))
    }

    // MARK: acceptance decision table

    private func outcome(_ settle: NativeZoomSettle, target: CGRect? = nil) -> NativeZoomOutcome {
        nativeZoomOutcome(settle: settle, target: target ?? self.target, visible: visible)
    }

    func testFrameWithinTwoPointsInsideTheDisplayIsExact() {
        XCTAssertEqual(outcome(.settled(target, milliseconds: 300)), .exact)
        // Exactly 2 pt on the worst edge still counts.
        XCTAssertEqual(outcome(.settled(target.offsetBy(dx: 2, dy: -2), milliseconds: 300)), .exact)
    }

    func testTheFullVisibleFrameIsCorrectedToTheGappedTarget() {
        // The macOS zoom fills the visible frame: the tiling gaps are gone, so
        // one correcting write insets it back to the layout target.
        XCTAssertEqual(outcome(.settled(visible, milliseconds: 300)), .corrected)
        XCTAssertEqual(outcome(.settled(target.offsetBy(dx: 2.5, dy: 0), milliseconds: 300)), .corrected)
        // Formerly accepted as-is (up to 32 pt).
        let edge = CGRect(x: 40, y: 8, width: 1552, height: 884)
        XCTAssertEqual(outcome(.settled(edge, milliseconds: 1)), .corrected)
    }

    func testFrameSpillingOutsideTheVisibleFrameIsNotExactEvenWhenClose() {
        let spilling = CGRect(x: -20, y: 8, width: 1620, height: 884)
        XCTAssertEqual(outcome(.settled(spilling, milliseconds: 300)), .corrected)
    }

    func testFrameWithinNinetySixPointsIsCorrected() {
        let off = CGRect(x: 8 + 60, y: 8, width: 1584 - 60, height: 884)
        XCTAssertEqual(outcome(.settled(off, milliseconds: 300)), .corrected)
        let exactly = CGRect(x: 8 + 96, y: 8, width: 1584 - 96, height: 884)
        XCTAssertEqual(outcome(.settled(exactly, milliseconds: 300)), .corrected)
    }

    func testFrameBeyondNinetySixFallsBack() {
        let small = CGRect(x: 8 + 200, y: 8, width: 1584 - 200, height: 884)
        XCTAssertEqual(outcome(.settled(small, milliseconds: 300)), .fallback(.mismatch))
        // An app whose zoom is not full size (a capped content window).
        let capped = CGRect(x: 300, y: 100, width: 1000, height: 700)
        XCTAssertEqual(outcome(.settled(capped, milliseconds: 300)), .fallback(.mismatch))
    }

    func testNoChangeTimeoutAndFailedPressFallBackWithTheirReason() {
        XCTAssertEqual(outcome(.unchanged(milliseconds: 1500)), .fallback(.unchanged))
        XCTAssertEqual(outcome(.timedOut(milliseconds: 1500)), .fallback(.timeout))
        XCTAssertEqual(outcome(.pressFailed(code: -25206)), .fallback(.pressFailed))
        XCTAssertEqual(outcome(.pressFailed(code: nil)), .fallback(.pressFailed))
    }

    func testRestoreUsesTheSameTableAgainstTheTiledTarget() {
        let tiled = CGRect(x: 8, y: 8, width: 780, height: 884)
        XCTAssertEqual(outcome(.settled(tiled.offsetBy(dx: 1, dy: 0), milliseconds: 200), target: tiled), .exact)
        XCTAssertEqual(outcome(.settled(tiled.offsetBy(dx: 10, dy: 0), milliseconds: 200), target: tiled), .corrected)
        XCTAssertEqual(outcome(.settled(tiled.offsetBy(dx: 70, dy: 0), milliseconds: 200), target: tiled), .corrected)
        XCTAssertEqual(outcome(.settled(target, milliseconds: 200), target: tiled), .fallback(.mismatch))
    }

    func testLimitsWaitLongEnoughForTheAppsZoomAnimation() {
        XCTAssertEqual(NativeZoomLimits.acceptTolerance, 2)
        XCTAssertEqual(NativeZoomLimits.settleTimeout, 1.5)
        XCTAssertEqual(NativeZoomLimits.zoomMessagingTimeout, 1.0)
    }

    // MARK: zoom action errors: pending vs definitive

    func testTimeoutClassErrorsArePendingAndTheRestAreDefinitive() {
        // kAXErrorCannotComplete is what a messaging timeout reports while the
        // app is busy running its own zoom animation.
        XCTAssertEqual(nativeZoomActionErrorClass(-25204), .pending)
        for code in [Int32(-25200), -25201, -25202, -25206, -25208, -25211, -25212] {
            XCTAssertEqual(nativeZoomActionErrorClass(code), .definitive, "code \(code)")
        }
    }

    func testActionStatusMapsToPressedPendingOrFailed() {
        XCTAssertEqual(zoomPressResult(forActionStatus: 0), .pressed)
        XCTAssertEqual(zoomPressResult(forActionStatus: -25204), .pending(code: -25204))
        XCTAssertEqual(zoomPressResult(forActionStatus: -25206), .failed(code: -25206))
    }

    func testPendingPressKeepsWatchingWhileDefinitiveFailuresFallBackNow() {
        XCTAssertEqual(nativeZoomPressDisposition(.pressed), .watch)
        XCTAssertEqual(nativeZoomPressDisposition(.pending(code: -25204)), .watch)
        XCTAssertEqual(nativeZoomPressDisposition(.pending(code: nil)), .watch)
        XCTAssertEqual(nativeZoomPressDisposition(.failed(code: -25206)), .fallbackNow(.pressFailed(code: -25206)))
        XCTAssertEqual(nativeZoomPressDisposition(.unavailable("noWindow")), .fallbackNow(.pressFailed(code: nil)))
    }

    func testAPendingZoomIsNeverWrittenUntilItIsJudged() {
        var book = NativeZoomBook()
        book.begin(id(1), action: .maximize)
        let frames = [id(1): target, id(2): visible]
        // The press is pending (no finish yet): the zoomed window is left alone.
        XCTAssertEqual(book.withoutInFlight(frames), [id(2): visible])
        XCTAssertTrue(book.isBusy(id(1)))
        // The settle ended: it is out of flight but waits for its single verdict.
        book.finish(id(1), settle: .settled(visible, milliseconds: 400))
        XCTAssertEqual(book.withoutInFlight(frames), frames)
        XCTAssertTrue(book.hasResolved)
    }

    func testLogLineNamesEveryFallbackReason() {
        for reason in [NativeZoomFallbackReason.unavailable, .noWindowServer, .notVisible, .pressFailed, .unchanged, .mismatch] {
            XCTAssertTrue(
                nativeZoomLogLine(id: id(1), app: "A", action: .maximize, outcome: .fallback(reason), milliseconds: 0)
                    .contains("result=fallback(\(reason.rawValue))")
            )
        }
    }

    func testLogLineHasIdsAppActionResultAndMillisecondsButNoTitle() {
        XCTAssertEqual(
            nativeZoomLogLine(id: id(42, 7), app: "Code", action: .maximize, outcome: .exact, milliseconds: 412),
            "native zoom id=42:7 app=Code action=maximize result=exact ms=412"
        )
        XCTAssertEqual(
            nativeZoomLogLine(id: id(42, 7), app: "Code", action: .restore, outcome: .corrected, milliseconds: 90),
            "native zoom id=42:7 app=Code action=restore result=corrected ms=90"
        )
        XCTAssertEqual(
            nativeZoomLogLine(id: id(42, 7), app: "Code", action: .maximize, outcome: .fallback(.timeout), milliseconds: 1200),
            "native zoom id=42:7 app=Code action=maximize result=fallback(timeout) ms=1200"
        )
        XCTAssertEqual(
            nativeZoomLogLine(
                id: id(42, 7), app: "Code", action: .maximize, outcome: .fallback(.pressFailed), milliseconds: 0,
                errorCode: -25206
            ),
            "native zoom id=42:7 app=Code action=maximize result=fallback(pressFailed:-25206) ms=0"
        )
    }

    // MARK: settle detection

    private let start = CGRect(x: 8, y: 8, width: 780, height: 884)

    /// Polls every 16 ms from `from` to `to` (inclusive) with the same bounds.
    private func poll(
        _ tracker: inout NativeZoomSettleTracker, _ bounds: CGRect?, from: Int, to: Int
    ) -> NativeZoomSettle? {
        var ms = from
        while ms <= to {
            if let settle = tracker.observe(bounds, elapsed: TimeInterval(ms) / 1000) {
                return settle
            }
            ms += 16
        }
        return nil
    }

    func testSettlesOnlyAfterTheQuietPeriodFollowingTheLastChange() {
        var tracker = NativeZoomSettleTracker(start: start)
        let final = CGRect(x: 8, y: 8, width: 1584, height: 884)
        XCTAssertNil(tracker.observe(start, elapsed: 0.016))
        XCTAssertNil(tracker.observe(start, elapsed: 0.5))
        // The app repaints late, then animates: every frame differs.
        XCTAssertNil(tracker.observe(CGRect(x: 8, y: 8, width: 900, height: 884), elapsed: 0.6))
        XCTAssertNil(tracker.observe(CGRect(x: 8, y: 8, width: 1200, height: 884), elapsed: 0.616))
        XCTAssertNil(tracker.observe(final, elapsed: 0.632))
        // Two equal polls are no longer a settle: the quiet period must pass.
        XCTAssertNil(tracker.observe(final, elapsed: 0.648))
        XCTAssertNil(tracker.observe(final, elapsed: 0.664))
        XCTAssertNil(tracker.observe(final, elapsed: 0.781))
        XCTAssertEqual(
            tracker.observe(final, elapsed: 0.782),
            .settled(final, milliseconds: 782, settleMilliseconds: 632)
        )
    }

    func testAMultiStageZoomWithAPauseDoesNotSettleOnTheIntermediateFrame() {
        var tracker = NativeZoomSettleTracker(start: start)
        let stageOne = CGRect(x: 8, y: 8, width: 1584, height: 500)
        let final = CGRect(x: 0, y: 0, width: 1600, height: 900)
        XCTAssertNil(tracker.observe(stageOne, elapsed: 0.016))
        // The app pauses 40 ms (the real logs settled at ~35 ms here)...
        XCTAssertNil(poll(&tracker, stageOne, from: 32, to: 56))
        // ...and then runs the second stage.
        XCTAssertNil(tracker.observe(final, elapsed: 0.072))
        let settle = poll(&tracker, final, from: 88, to: 400)
        XCTAssertEqual(settle, .settled(final, milliseconds: 232, settleMilliseconds: 72))
    }

    func testSettleWaitsForTheMinimumTimeSinceThePress() {
        var tracker = NativeZoomSettleTracker(start: start, quietPeriod: 0.05, minimumElapsed: 0.12)
        let final = CGRect(x: 8, y: 8, width: 1584, height: 884)
        XCTAssertNil(tracker.observe(final, elapsed: 0.02))
        // Quiet for 60 ms already, but only 80 ms since the press.
        XCTAssertNil(tracker.observe(final, elapsed: 0.08))
        XCTAssertNil(tracker.observe(final, elapsed: 0.119))
        XCTAssertEqual(
            tracker.observe(final, elapsed: 0.12), .settled(final, milliseconds: 120, settleMilliseconds: 20)
        )
    }

    func testOneUnchangedSampleAfterTheStartIsNotASettle() {
        var tracker = NativeZoomSettleTracker(start: start)
        XCTAssertNil(tracker.observe(start, elapsed: 0.016))
        XCTAssertNil(tracker.observe(start, elapsed: 0.032))
        XCTAssertNil(tracker.observe(start, elapsed: 0.048))
        XCTAssertNil(tracker.observe(start, elapsed: 0.4))
    }

    func testJitterWithinOnePointCountsAsStableAndDoesNotRestartTheQuietPeriod() {
        var tracker = NativeZoomSettleTracker(start: start)
        XCTAssertNil(tracker.observe(CGRect(x: 8, y: 8, width: 1584, height: 884), elapsed: 0.3))
        XCTAssertNil(tracker.observe(CGRect(x: 8.5, y: 8, width: 1583.6, height: 884), elapsed: 0.316))
        XCTAssertNotNil(tracker.observe(CGRect(x: 8.5, y: 8, width: 1583.6, height: 884), elapsed: 0.45))
    }

    func testAChangeRestartsTheQuietPeriod() {
        var tracker = NativeZoomSettleTracker(start: start)
        let a = CGRect(x: 8, y: 8, width: 1000, height: 884)
        let b = CGRect(x: 8, y: 8, width: 1300, height: 884)
        XCTAssertNil(tracker.observe(a, elapsed: 0.3))
        XCTAssertNil(tracker.observe(b, elapsed: 0.44))
        XCTAssertNil(tracker.observe(b, elapsed: 0.5))
        XCTAssertEqual(tracker.observe(b, elapsed: 0.59), .settled(b, milliseconds: 590, settleMilliseconds: 440))
    }

    func testTimesOutUnchangedWhenTheWindowNeverMoved() {
        var tracker = NativeZoomSettleTracker(start: start)
        XCTAssertNil(tracker.observe(start, elapsed: 1.49))
        XCTAssertEqual(tracker.observe(start, elapsed: 1.5), .unchanged(milliseconds: 1500))
    }

    func testTimesOutWhenItChangedButNeverSettled() {
        var tracker = NativeZoomSettleTracker(start: start)
        XCTAssertNil(tracker.observe(CGRect(x: 8, y: 8, width: 900, height: 884), elapsed: 1.0))
        XCTAssertEqual(
            tracker.observe(CGRect(x: 8, y: 8, width: 1000, height: 884), elapsed: 1.51), .timedOut(milliseconds: 1510)
        )
    }

    func testMissingWindowServerEntryOnlyEndsAtTheTimeout() {
        var tracker = NativeZoomSettleTracker(start: start)
        XCTAssertNil(tracker.observe(nil, elapsed: 0.5))
        XCTAssertEqual(tracker.observe(nil, elapsed: 1.6), .unchanged(milliseconds: 1600))
    }

    // MARK: book: in flight, resolved, accepted

    func testInFlightWindowsAreExcludedFromWrites() {
        var book = NativeZoomBook()
        book.begin(id(1), action: .maximize)
        XCTAssertTrue(book.isInFlight(id(1)))
        let frames = [id(1): target, id(2): start]
        XCTAssertEqual(book.withoutInFlight(frames), [id(2): start])
        XCTAssertEqual(book.withoutInFlight([id(3): start]), [id(3): start])
        XCTAssertEqual(book.inFlightIDs, [id(1)])
    }

    func testFinishMovesAFlightToResolvedOnceAndLeavesFlight() {
        var book = NativeZoomBook()
        book.begin(id(1), action: .restore)
        book.finish(id(1), settle: .timedOut(milliseconds: 1200))
        XCTAssertFalse(book.isInFlight(id(1)))
        let resolved = book.takeResolved()
        XCTAssertEqual(resolved.map(\.id), [id(1)])
        XCTAssertEqual(resolved.first?.action, .restore)
        XCTAssertEqual(resolved.first?.settle, .timedOut(milliseconds: 1200))
        XCTAssertTrue(book.takeResolved().isEmpty)
    }

    func testABusyWindowIsInFlightOrWaitingForItsVerdict() {
        var book = NativeZoomBook()
        XCTAssertFalse(book.isBusy(id(1)))
        book.begin(id(1), action: .maximize)
        XCTAssertTrue(book.isBusy(id(1)))
        book.finish(id(1), settle: .unchanged(milliseconds: 1200))
        XCTAssertFalse(book.isInFlight(id(1)))
        XCTAssertTrue(book.isBusy(id(1)), "the verdict is still pending: its events stay expected")
        XCTAssertTrue(book.hasResolved)
        _ = book.takeResolved()
        XCTAssertFalse(book.isBusy(id(1)))
    }

    func testFinishIgnoresAWindowThatIsNotInFlight() {
        var book = NativeZoomBook()
        book.finish(id(9), settle: .pressFailed(code: nil))
        XCTAssertTrue(book.takeResolved().isEmpty)
    }

    func testAcceptedFrameReplacesTheTargetWhileTheLayoutTargetIsUnchanged() {
        var book = NativeZoomBook()
        let actual = CGRect(x: 0, y: 0, width: 1600, height: 900)
        book.accept(id(1), target: target, actual: actual)
        XCTAssertTrue(book.isNativeMaximized(id(1)))
        let frames = book.applyAccepted(to: [id(1): target, id(2): start], parked: [])
        XCTAssertEqual(frames[id(1)], actual)
        XCTAssertEqual(frames[id(2)], start)
        XCTAssertTrue(book.isNativeMaximized(id(1)))
    }

    func testAcceptedFrameIsDroppedWhenTheLayoutTargetMoves() {
        var book = NativeZoomBook()
        book.accept(id(1), target: target, actual: visible)
        let moved = book.applyAccepted(to: [id(1): target.offsetBy(dx: 40, dy: 0)], parked: [])
        XCTAssertEqual(moved[id(1)], target.offsetBy(dx: 40, dy: 0))
        XCTAssertFalse(book.isNativeMaximized(id(1)))
    }

    func testAcceptedFrameIsDroppedWhenTheWindowIsParked() {
        var book = NativeZoomBook()
        book.accept(id(1), target: target, actual: visible)
        _ = book.applyAccepted(to: [:], parked: [id(1)])
        XCTAssertFalse(book.isNativeMaximized(id(1)))
    }

    func testAcceptedFrameSurvivesAPlanThatDoesNotMentionTheWindow() {
        var book = NativeZoomBook()
        book.accept(id(1), target: target, actual: visible)
        _ = book.applyAccepted(to: [id(2): start], parked: [])
        XCTAssertTrue(book.isNativeMaximized(id(1)))
    }

    func testForgetClearsEverythingKnownAboutAWindow() {
        var book = NativeZoomBook()
        book.begin(id(1), action: .maximize)
        book.accept(id(1), target: target, actual: visible)
        book.forget(id(1))
        XCTAssertFalse(book.isInFlight(id(1)))
        XCTAssertFalse(book.isNativeMaximized(id(1)))
    }

    // MARK: event suppression

    func testFrameAndFocusEventsOfAFlyingWindowAreExpected() {
        for kind in [WindowEventKind.moved, .resized, .focusedWindowChanged] {
            XCTAssertTrue(nativeZoomDropsEvent(kind, inFlight: true), "\(kind)")
            XCTAssertFalse(nativeZoomDropsEvent(kind, inFlight: false), "\(kind)")
        }
    }

    func testStructuralEventsAreNeverDroppedDuringAFlight() {
        for kind in [WindowEventKind.destroyed, .miniaturized, .deminiaturized, .windowCreated, .titleChanged] {
            XCTAssertFalse(nativeZoomDropsEvent(kind, inFlight: true), "\(kind)")
        }
    }

    // MARK: reconciler operation (lane-safe, per pid)

    private final class ZoomActuator: WindowActuator {
        private let lock = NSLock()
        private(set) var presses: [WindowID] = []
        private(set) var frameWrites = 0
        var availability: ZoomAvailability = .available
        var press: ZoomPressResult = .pressed

        func frame(of id: WindowID) throws -> CGRect? { nil }
        func setFrame(_ frame: CGRect, for id: WindowID) throws { lock.withLock { frameWrites += 1 } }
        func focus(id: WindowID) throws {}

        func zoomAvailability(of id: WindowID) -> ZoomAvailability { availability }

        func pressZoom(id: WindowID) -> ZoomPressResult {
            lock.withLock { presses.append(id) }
            return press
        }
    }

    func testReconcilerPressesTheZoomThroughTheActuatorWithoutWritingFrames() {
        let actuator = ZoomActuator()
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        XCTAssertEqual(reconciler.pressZoom(id(3)), .pressed)
        XCTAssertEqual(actuator.presses, [id(3)])
        XCTAssertEqual(actuator.frameWrites, 0)
    }

    func testReconcilerReportsAvailabilityAndRefusals() {
        let actuator = ZoomActuator()
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        XCTAssertEqual(reconciler.zoomAvailability(of: id(3)), .available)
        actuator.availability = .unavailable("noZoomButton")
        XCTAssertEqual(reconciler.zoomAvailability(of: id(3)), .unavailable("noZoomButton"))
        actuator.press = .unavailable("disabled")
        XCTAssertEqual(reconciler.pressZoom(id(3)), .unavailable("disabled"))
    }

    func testAnActuatorWithoutZoomSupportReportsUnavailable() {
        final class Plain: WindowActuator {
            func frame(of id: WindowID) throws -> CGRect? { nil }
            func setFrame(_ frame: CGRect, for id: WindowID) throws {}
            func focus(id: WindowID) throws {}
        }
        let reconciler = WindowReconciler(actuator: Plain(), concurrency: .serial)
        XCTAssertEqual(reconciler.zoomAvailability(of: id(1)), .unavailable("unsupported"))
        XCTAssertEqual(reconciler.pressZoom(id(1)), .unavailable("unsupported"))
    }

    func testReconcilerPressAlsoWorksOnTheConcurrentLanes() {
        let actuator = ZoomActuator()
        let reconciler = WindowReconciler(actuator: actuator)
        XCTAssertEqual(reconciler.pressZoom(id(3)), .pressed)
        XCTAssertEqual(actuator.presses, [id(3)])
    }

    // MARK: post-correction verification (single reassert)

    private let landed = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testVerifiedWhenTheWindowIsAtTheTargetAndNeverReasserts() {
        var verifier = NativeZoomVerifier(target: target, before: landed)
        XCTAssertEqual(verifier.observe(target.offsetBy(dx: 2, dy: -2), writeFailed: false), .verified)
    }

    func testReassertsOnceWhenTheAppOverwroteTheCorrection() {
        var verifier = NativeZoomVerifier(target: target, before: landed)
        // The app's zoom finished after our write: it sits at its own frame
        // (the same as before the write), not at the target.
        XCTAssertEqual(verifier.observe(landed, writeFailed: false), .reassert(.overwritten))
        // After the one reassert it lands...
        XCTAssertEqual(verifier.observe(target, writeFailed: false), .verified)
    }

    func testNeverReassertsTwice() {
        var verifier = NativeZoomVerifier(target: target, before: landed)
        XCTAssertEqual(verifier.observe(landed, writeFailed: false), .reassert(.overwritten))
        XCTAssertEqual(verifier.observe(landed, writeFailed: false), .unverified)
        XCTAssertEqual(verifier.observe(landed, writeFailed: true), .unverified)
    }

    func testAWriteFailureReassertsOnceEvenIfTheFrameIsUnknown() {
        var verifier = NativeZoomVerifier(target: target, before: landed)
        XCTAssertEqual(verifier.observe(landed, writeFailed: true), .reassert(.writeFailed))
        XCTAssertEqual(verifier.observe(landed, writeFailed: true), .unverified)
    }

    func testAWriteFailureThatStillLandedAtTheTargetIsVerified() {
        var verifier = NativeZoomVerifier(target: target, before: landed)
        XCTAssertEqual(verifier.observe(target, writeFailed: true), .verified)
    }

    func testABoundsStillMovingAreRecheckedAfterTheQuietPeriodBeforeReasserting() {
        var verifier = NativeZoomVerifier(target: target, before: landed)
        let mid = CGRect(x: 4, y: 4, width: 1592, height: 892)
        // Neither the target nor the pre-write frame: the app is still animating.
        XCTAssertEqual(verifier.observe(mid, writeFailed: false), .recheck)
        // Held still and wrong: now it is an overwrite.
        XCTAssertEqual(verifier.observe(mid, writeFailed: false), .reassert(.overwritten))
    }

    func testARecheckIsAllowedOnlyOnce() {
        var verifier = NativeZoomVerifier(target: target, before: landed)
        XCTAssertEqual(verifier.observe(CGRect(x: 1, y: 1, width: 1590, height: 890), writeFailed: false), .recheck)
        // Still moving after the recheck: reassert anyway (one reassert, no endless waiting).
        XCTAssertEqual(
            verifier.observe(CGRect(x: 3, y: 3, width: 1594, height: 894), writeFailed: false), .reassert(.overwritten)
        )
    }

    func testAnUnlistedWindowCannotBeVerified() {
        var verifier = NativeZoomVerifier(target: target, before: landed)
        XCTAssertEqual(verifier.observe(nil, writeFailed: false), .unverified)
    }

    func testVerificationTimingsAreTheDocumentedOnes() {
        XCTAssertEqual(NativeZoomLimits.verifyDelay, 0.25)
        XCTAssertEqual(NativeZoomLimits.quietPeriod, 0.15)
        XCTAssertEqual(NativeZoomLimits.minimumSettleElapsed, 0.12)
    }

    func testTheBookKeepsAVerifyingWindowBusyUntilItEnds() {
        var book = NativeZoomBook()
        book.beginVerifying(id(1))
        XCTAssertTrue(book.isBusy(id(1)))
        XCTAssertTrue(book.isVerifying(id(1)))
        XCTAssertFalse(book.isInFlight(id(1)))
        book.endVerifying(id(1))
        XCTAssertFalse(book.isBusy(id(1)))
        book.beginVerifying(id(2))
        book.forget(id(2))
        XCTAssertFalse(book.isBusy(id(2)))
    }

    func testLogLineCarriesSettleMillisecondsAndVerifiedWhenKnown() {
        XCTAssertEqual(
            nativeZoomLogLine(
                id: id(42, 7), app: "Figma", action: .maximize, outcome: .fallback(.mismatch), milliseconds: 232,
                settleMilliseconds: 72, verified: true
            ),
            "native zoom id=42:7 app=Figma action=maximize result=fallback(mismatch) ms=232 settleMs=72 verified=true"
        )
        XCTAssertEqual(
            nativeZoomLogLine(
                id: id(42, 7), app: "Pen", action: .maximize, outcome: .corrected, milliseconds: 200, verified: false
            ),
            "native zoom id=42:7 app=Pen action=maximize result=corrected ms=200 verified=false"
        )
    }

    func testReassertLogLineNamesTheReasonAndNoTitle() {
        XCTAssertEqual(
            nativeZoomReassertLogLine(id: id(42, 7), app: "Pen", reason: .writeFailed),
            "native zoom reassert id=42:7 app=Pen reason=writeFailed"
        )
        XCTAssertEqual(
            nativeZoomReassertLogLine(id: id(42, 7), app: "Figma", reason: .overwritten),
            "native zoom reassert id=42:7 app=Figma reason=overwritten"
        )
    }

    // MARK: config

    func testNativeZoomDefaultsToOnAndParses() throws {
        XCTAssertTrue(defaultGioConfig().animations.nativeZoom)
        for value in [true, false] {
            let (config, warnings) = try parseGioConfig("[animations]\nnative-zoom = \(value)\n").get()
            XCTAssertTrue(warnings.isEmpty)
            XCTAssertEqual(config.animations.nativeZoom, value)
        }
        XCTAssertThrowsError(try parseGioConfig("[animations]\nnative-zoom = \"yes\"\n").get())
    }

    func testTemplateDeclaresNativeZoomAndEditsCarryIt() throws {
        XCTAssertTrue(defaultConfigTemplate().contains("native-zoom = true"))
        let (config, warnings) = try parseGioConfig(defaultConfigTemplate()).get()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(config.animations.nativeZoom)
        XCTAssertEqual(
            animationEdits(enabled: true, durationMilliseconds: 200, nativeZoom: false).last,
            .set(table: "animations", key: "native-zoom", value: .bool(false))
        )
        XCTAssertFalse(
            animationEdits(enabled: true, durationMilliseconds: 200).contains {
                if case .set(_, "native-zoom", _) = $0 { return true } else { return false }
            }
        )
    }
}
