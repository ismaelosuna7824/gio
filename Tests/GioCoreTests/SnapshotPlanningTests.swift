import CoreGraphics
import XCTest
@testable import GioCore

/// SM-02: the pure decisions behind the ScreenCaptureKit capture module.
final class SnapshotPlanningTests: XCTestCase {
    private func id(_ n: Int, pid: pid_t = 100) -> WindowID { WindowID(pid: pid, elementID: UInt64(n)) }
    private func candidate(_ window: UInt32, pid: pid_t = 100, _ frame: CGRect) -> SnapshotCandidate {
        SnapshotCandidate(windowID: window, pid: pid, frame: frame)
    }
    private let a = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let b = CGRect(x: 800, y: 0, width: 800, height: 600)

    // MARK: coordinates

    func testSCKFrameIsTopLeftGlobalAndFlipsToCocoa() {
        // SCWindow.frame: global, origin top-left of the primary display.
        let sck = CGRect(x: 100, y: 50, width: 400, height: 300)
        let cocoa = snapshotCocoaFrame(fromSCK: sck, primaryDisplayHeight: 1000)
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 650, width: 400, height: 300))
        XCTAssertEqual(snapshotCocoaFrame(fromSCK: cocoa, primaryDisplayHeight: 1000), sck)
    }

    func testPixelSizeScalesAndRoundsUp() {
        XCTAssertEqual(snapshotPixelSize(points: CGSize(width: 800, height: 600), scale: 2).width, 1600)
        XCTAssertEqual(snapshotPixelSize(points: CGSize(width: 800.5, height: 600.2), scale: 2).width, 1601)
        XCTAssertEqual(snapshotPixelSize(points: CGSize(width: 800.5, height: 600.2), scale: 2).height, 1201)
        XCTAssertEqual(snapshotPixelSize(points: CGSize(width: 0, height: 10), scale: 2).width, 1)
    }

    func testBackingScaleUsesTheDisplayWithMostOverlap() {
        let displays = [
            SnapshotDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2),
            SnapshotDisplay(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), scale: 1),
        ]
        XCTAssertEqual(backingScale(for: CGRect(x: 900, y: 0, width: 400, height: 300), displays: displays), 1)
        XCTAssertEqual(backingScale(for: CGRect(x: 100, y: 0, width: 400, height: 300), displays: displays), 2)
        XCTAssertEqual(backingScale(for: CGRect(x: 5000, y: 0, width: 400, height: 300), displays: displays), 2)
        XCTAssertEqual(backingScale(for: a, displays: []), 2)
    }

    // MARK: matching

    func testExactFrameMatchesFirst() {
        let result = matchSnapshotCandidates(
            managed: [id(1): a, id(2): b],
            candidates: [candidate(11, a), candidate(12, b)]
        )
        XCTAssertEqual(result[id(1)], .matched(11))
        XCTAssertEqual(result[id(2)], .matched(12))
    }

    func testSamePidSameSizeExactClaimsBeforeUniqueSize() {
        // Two windows of one app with the same size: each takes its own entry.
        let result = matchSnapshotCandidates(
            managed: [id(1): a, id(2): b],
            candidates: [candidate(12, b), candidate(11, a)]
        )
        XCTAssertEqual(result[id(1)], .matched(11))
        XCTAssertEqual(result[id(2)], .matched(12))
    }

    func testUniqueSameSizeMatchesWhenPositionDiffers() {
        let moved = a.offsetBy(dx: 300, dy: 40)
        let result = matchSnapshotCandidates(managed: [id(1): a], candidates: [candidate(11, moved)])
        XCTAssertEqual(result[id(1)], .matched(11))
    }

    func testSeveralSameSizeCandidatesAreAmbiguous() {
        let result = matchSnapshotCandidates(
            managed: [id(1): a],
            candidates: [candidate(11, a.offsetBy(dx: 100, dy: 0)), candidate(12, a.offsetBy(dx: 200, dy: 0))]
        )
        XCTAssertEqual(result[id(1)], .ambiguous)
    }

    func testLearnedMinimumSizeMatchesTheUniqueNearFrame() {
        let ax = CGRect(x: 0, y: 0, width: 888, height: 600)
        let result = matchSnapshotCandidates(managed: [id(1): ax], candidates: [candidate(11, CGRect(x: 0, y: 0, width: 900, height: 600))])
        XCTAssertEqual(result[id(1)], .matched(11))
    }

    func testSeveralNearFramesStayAmbiguous() {
        let ax = CGRect(x: 0, y: 0, width: 888, height: 600)
        let result = matchSnapshotCandidates(
            managed: [id(1): ax],
            candidates: [
                candidate(11, CGRect(x: 0, y: 0, width: 900, height: 600)),
                candidate(12, CGRect(x: 2, y: 0, width: 910, height: 600)),
            ]
        )
        XCTAssertEqual(result[id(1)], .ambiguous)
    }

    func testOtherPidsAndOtherSizesAreMissing() {
        let result = matchSnapshotCandidates(
            managed: [id(1): a],
            candidates: [candidate(11, pid: 200, a), candidate(12, CGRect(x: 0, y: 0, width: 300, height: 300))]
        )
        XCTAssertEqual(result[id(1)], .missing)
    }

    func testEachCandidateIsClaimedOnce() {
        let result = matchSnapshotCandidates(managed: [id(1): a, id(2): a], candidates: [candidate(11, a)])
        XCTAssertEqual(result[id(1)], .matched(11))
        XCTAssertEqual(result[id(2)], .missing)
    }

    // MARK: SM-11 parked windows

    /// Gio writes the parking frame (1 pt sliver); macOS may clamp the
    /// position so up to `parkedStripLimit` points stay on screen. The size
    /// is kept, so a parked window of an app with one window of that size
    /// matches by its unique size.
    func testClampedParkedWindowMatchesByItsUniqueSize() {
        let parked = CGRect(x: 1799, y: 0, width: 800, height: 600)
        let clamped = parked.offsetBy(dx: -39, dy: 0)
        let result = matchSnapshotCandidates(
            managed: [id(1): parked, id(2): a],
            candidates: [candidate(11, a), candidate(12, clamped)]
        )
        XCTAssertEqual(result[id(1)], .matched(12))
        XCTAssertEqual(result[id(2)], .matched(11))
    }

    /// Two same-size windows of one app parked on both edges (columns of one
    /// width preset): each takes the same-size entry within clamp reach.
    func testClampedParkedWindowsOfOneSizeTakeTheEntryWithinClampReach() {
        let left = CGRect(x: -799, y: 0, width: 800, height: 600)
        let right = CGRect(x: 1799, y: 0, width: 800, height: 600)
        let result = matchSnapshotCandidates(
            managed: [id(1): left, id(2): right],
            candidates: [candidate(12, right.offsetBy(dx: -30, dy: 0)), candidate(11, left.offsetBy(dx: 25, dy: 0))]
        )
        XCTAssertEqual(result[id(1)], .matched(11))
        XCTAssertEqual(result[id(2)], .matched(12))
    }

    func testTwoSameSizeEntriesWithinClampReachStayAmbiguous() {
        let right = CGRect(x: 1799, y: 0, width: 800, height: 600)
        let result = matchSnapshotCandidates(
            managed: [id(1): right],
            candidates: [candidate(11, right.offsetBy(dx: -10, dy: 0)), candidate(12, right.offsetBy(dx: -30, dy: 0))]
        )
        XCTAssertEqual(result[id(1)], .ambiguous)
    }

    // MARK: SM-13 same-size windows parked on one side

    /// Columns of one width preset parked on the same side get the same
    /// parking frame: without a learned id nothing tells them apart, so
    /// neither is guessed (never a swapped image).
    func testSameSizeWindowsParkedAtOneFrameAreNeverGuessed() {
        let right = CGRect(x: 1799, y: 0, width: 800, height: 600)
        let result = matchSnapshotCandidates(
            managed: [id(1): right, id(2): right],
            candidates: [candidate(12, right), candidate(11, right)]
        )
        XCTAssertEqual(result[id(1)], .ambiguous)
        XCTAssertEqual(result[id(2)], .ambiguous)
    }

    /// The CGWindowID learned while each window was visible identifies it
    /// while parked, whatever the order or the clamp of the entries.
    func testSameSizeParkedWindowsTakeTheWindowIDLearnedWhileVisible() {
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)
        let first = CGRect(x: 0, y: 0, width: 800, height: 600)
        let second = CGRect(x: 820, y: 0, width: 800, height: 600)
        var book = SnapshotWindowIDBook()
        let visible = [id(1): first, id(2): second]
        let seen = [candidate(11, first), candidate(12, second)]
        book.learn(
            matches: matchSnapshotCandidates(managed: visible, candidates: seen, known: book.known),
            frames: visible, displays: [display], candidates: seen
        )
        XCTAssertEqual(book.known, [id(1): 11, id(2): 12])

        let right = CGRect(x: 1799, y: 0, width: 800, height: 600)
        let clamped = right.offsetBy(dx: -39, dy: 0)
        for parkedEntries in [
            [candidate(12, clamped), candidate(11, clamped)], [candidate(11, right), candidate(12, right)],
        ] {
            let result = matchSnapshotCandidates(
                managed: [id(1): right, id(2): right], candidates: parkedEntries, known: book.known
            )
            XCTAssertEqual(result[id(1)], .matched(11))
            XCTAssertEqual(result[id(2)], .matched(12))
        }
    }

    func testTheBookLearnsOnlyOnScreenMatchesAndForgetsClosedWindows() {
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)
        let right = CGRect(x: 1799, y: 0, width: 800, height: 600)
        var book = SnapshotWindowIDBook()
        let parkedEntry = [candidate(11, right)]
        book.learn(
            matches: [id(1): .matched(11)], frames: [id(1): right], displays: [display], candidates: parkedEntry
        )
        XCTAssertTrue(book.known.isEmpty, "a parked match is not proof of identity")
        let entries = [candidate(11, a)]
        book.learn(matches: [id(1): .matched(11)], frames: [id(1): a], displays: [display], candidates: entries)
        XCTAssertEqual(book.known, [id(1): 11])
        // The app's windows are listed again without 11: that window closed.
        book.learn(matches: [:], frames: [id(2): a], displays: [display], candidates: [candidate(13, a)])
        XCTAssertTrue(book.known.isEmpty)
    }

    func testALearnedIDThatIsGoneFallsBackToTheFrameRules() {
        let result = matchSnapshotCandidates(
            managed: [id(1): a], candidates: [candidate(14, a)], known: [id(1): 11]
        )
        XCTAssertEqual(result[id(1)], .matched(14))
    }

    // MARK: SM-17 title tie-break of same-size parked windows

    /// Synthetic window names only (never real titles in assertions).
    private func named(_ window: UInt32, _ title: String?, _ frame: CGRect) -> SnapshotCandidate {
        SnapshotCandidate(windowID: window, pid: 100, frame: frame, title: title)
    }

    private let parkedRight = CGRect(x: 1799, y: 0, width: 800, height: 600)

    /// Same-size windows of one app parked at one frame, never seen on
    /// screen: the one candidate whose window name equals the window's AX
    /// title is its entry, in any listing order and with any clamp.
    func testDistinctTitlesBreakTheTieOfSameSizeParkedWindows() {
        let managed = [id(1): parkedRight, id(2): parkedRight, id(3): parkedRight]
        let titles = [id(1): "T-one", id(2): "T-two", id(3): "T-three"]
        let clamped = parkedRight.offsetBy(dx: -39, dy: 0)
        for entries in [
            [named(12, "T-two", parkedRight), named(13, "T-three", parkedRight), named(11, "T-one", parkedRight)],
            [named(11, "T-one", clamped), named(13, "T-three", clamped), named(12, "T-two", clamped)],
        ] {
            let matches = matchSnapshotCandidates(managed: managed, candidates: entries)
            XCTAssertTrue(matches.values.allSatisfy { $0 == .ambiguous }, "frames alone cannot tell them apart")
            let ties = snapshotTitleTieBreaks(
                managed: managed, candidates: entries, matches: matches, titles: titles
            )
            XCTAssertEqual(ties, [id(1): 11, id(2): 12, id(3): 13])
        }
        let two = [id(1): parkedRight, id(2): parkedRight]
        let entries = [named(12, "T-two", parkedRight), named(11, "T-one", parkedRight)]
        XCTAssertEqual(
            snapshotTitleTieBreaks(
                managed: two, candidates: entries,
                matches: matchSnapshotCandidates(managed: two, candidates: entries), titles: titles
            ),
            [id(1): 11, id(2): 12]
        )
    }

    func testEqualTitlesStayAmbiguous() {
        let managed = [id(1): parkedRight, id(2): parkedRight]
        let entries = [named(11, "T-same", parkedRight), named(12, "T-same", parkedRight)]
        let matches = matchSnapshotCandidates(managed: managed, candidates: entries)
        XCTAssertEqual(
            snapshotTitleTieBreaks(
                managed: managed, candidates: entries, matches: matches, titles: [id(1): "T-same", id(2): "T-same"]
            ),
            [:]
        )
        // Two windows with one title and a listing that names only one of
        // them (the other renamed in between): neither is guessed.
        let raced = [named(11, "T-same", parkedRight), named(12, "T-other", parkedRight)]
        XCTAssertEqual(
            snapshotTitleTieBreaks(
                managed: managed, candidates: raced,
                matches: matchSnapshotCandidates(managed: managed, candidates: raced),
                titles: [id(1): "T-same", id(2): "T-same"]
            ),
            [:]
        )
    }

    func testAMissingTitleOnEitherSideStaysAmbiguous() {
        let managed = [id(1): parkedRight, id(2): parkedRight]
        let entries = [named(11, "T-one", parkedRight), named(12, nil, parkedRight)]
        let matches = matchSnapshotCandidates(managed: managed, candidates: entries)
        let ties = snapshotTitleTieBreaks(
            managed: managed, candidates: entries, matches: matches, titles: [id(1): "", id(2): "T-two"]
        )
        XCTAssertEqual(ties, [:], "an empty AX title and an unnamed entry match nothing")
        let unnamed = [named(11, nil, parkedRight), named(12, nil, parkedRight)]
        XCTAssertEqual(
            snapshotTitleTieBreaks(
                managed: managed, candidates: unnamed,
                matches: matchSnapshotCandidates(managed: managed, candidates: unnamed),
                titles: [id(1): "T-one", id(2): "T-two"]
            ),
            [:], "no window names (no Screen Recording): stays ambiguous"
        )
        XCTAssertEqual(
            snapshotTitleTieBreaks(
                managed: managed, candidates: [named(11, "T-one", parkedRight), named(12, "T-two", parkedRight)],
                matches: [id(1): .ambiguous, id(2): .ambiguous], titles: [id(2): "T-two"]
            ),
            [id(2): 12], "the window without a title stays ambiguous, the other is told apart"
        )
    }

    /// Only ambiguous windows are tie-broken, never onto an entry another
    /// window already holds, never across apps or sizes, and the pick never
    /// leaves the entries within clamp reach when some are.
    func testTheTieBreakNeverSwapsOrStealsAnEntry() {
        let managed = [id(1): parkedRight, id(2): parkedRight, id(3): a]
        let entries = [
            named(11, "T-one", parkedRight), named(12, "T-one", parkedRight), named(13, "T-three", a),
            SnapshotCandidate(windowID: 21, pid: 200, frame: parkedRight, title: "T-two"),
            named(14, "T-two", CGRect(x: 1799, y: 0, width: 700, height: 600)),
            named(15, "T-two", parkedRight.offsetBy(dx: 0, dy: 300)),
            named(16, "T-x", parkedRight.offsetBy(dx: -20, dy: 0)),
        ]
        let matches: [WindowID: SnapshotMatch] = [id(1): .matched(12), id(2): .ambiguous, id(3): .matched(13)]
        let ties = snapshotTitleTieBreaks(
            managed: managed, candidates: entries, matches: matches,
            titles: [id(1): "T-one", id(2): "T-two", id(3): "T-three"]
        )
        XCTAssertEqual(ties, [:], "other pid, other size, or outside the clamp reach of the twins")
        let held = snapshotTitleTieBreaks(
            managed: managed, candidates: entries, matches: matches,
            titles: [id(1): "T-one", id(2): "T-one", id(3): "T-three"]
        )
        XCTAssertEqual(held, [id(2): 11], "window 1 already holds the other entry of that name")
    }

    /// A tie-broken match is proof of identity: the book keeps it even while
    /// the window is parked, so later passes need no title.
    func testTheBookLearnsTieBrokenMatchesWhereverTheWindowIs() {
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)
        var book = SnapshotWindowIDBook()
        let entries = [candidate(11, parkedRight), candidate(12, parkedRight)]
        book.learn(
            matches: [id(1): .matched(11), id(2): .matched(12)], frames: [id(1): parkedRight, id(2): parkedRight],
            displays: [display], candidates: entries, identified: [id(2)]
        )
        XCTAssertEqual(book.known, [id(2): 12])
        let later = matchSnapshotCandidates(
            managed: [id(1): parkedRight, id(2): parkedRight], candidates: entries.reversed(), known: book.known
        )
        XCTAssertEqual(later[id(2)], .matched(12))
        XCTAssertEqual(later[id(1)], .matched(11), "the twin left alone is unique once the other is known")
    }

    func testTieBreakLogLineAndCandidateDescriptionsCarryNoTitle() {
        XCTAssertEqual(
            snapshotTieBreakLogLine(WindowID(pid: 5618, elementID: 3), by: .title), "snapshot match tie-break id=5618:3 by=title"
        )
        XCTAssertEqual(
            snapshotTieBreakLogLine(WindowID(pid: 5618, elementID: 4), by: .order), "snapshot match tie-break id=5618:4 by=order"
        )
        let entry = SnapshotCandidate(windowID: 7, pid: 9, frame: a, title: "T-hidden")
        for text in [String(describing: entry), String(reflecting: entry), "\(entry)", String(describing: [entry])] {
            XCTAssertFalse(text.contains("T-hidden"))
            XCTAssertTrue(text.contains("7"))
        }
        var dumped = ""
        dump(entry, to: &dumped)
        XCTAssertFalse(dumped.contains("T-hidden"))
    }

    // MARK: SM-20 stacking-order tie-break

    /// Same-size parked windows with equal or missing titles: the app's AX
    /// window order (front to back) is matched rank to rank against the
    /// on-screen stacking (front to back) of the unheld same-size entries.
    func testStackingOrderBreaksTheTieOfTwoSameSizeWindows() {
        let managed = [id(1): parkedRight, id(2): parkedRight]
        let entries = [candidate(11, parkedRight), candidate(12, parkedRight)]
        let matches = matchSnapshotCandidates(managed: managed, candidates: entries)
        XCTAssertTrue(matches.values.allSatisfy { $0 == .ambiguous })
        XCTAssertEqual(
            snapshotOrderTieBreaks(
                managed: managed, candidates: entries, matches: matches,
                axOrder: [100: [id(2), id(1)]], stacking: [12, 11]
            ),
            [id(2): 12, id(1): 11]
        )
        XCTAssertEqual(
            snapshotOrderTieBreaks(
                managed: managed, candidates: entries, matches: matches,
                axOrder: [100: [id(2), id(1)]], stacking: [11, 12]
            ),
            [id(2): 11, id(1): 12], "rank to rank, whatever the ids or the listing order"
        )
    }

    func testStackingOrderBreaksTheTieOfThreeSameSizeWindows() {
        let managed = [id(1): parkedRight, id(2): parkedRight, id(3): parkedRight]
        let entries = [candidate(13, parkedRight), candidate(11, parkedRight), candidate(12, parkedRight)]
        let matches = matchSnapshotCandidates(managed: managed, candidates: entries)
        // Other apps' windows and an unmanaged window of the app (id 9, a
        // palette) interleave both orders; only the ranks among the tied
        // windows and their entries count.
        XCTAssertEqual(
            snapshotOrderTieBreaks(
                managed: managed, candidates: entries, matches: matches,
                axOrder: [100: [id(3), id(9), id(1), id(2)]], stacking: [5, 12, 40, 13, 11]
            ),
            [id(3): 12, id(1): 13, id(2): 11]
        )
    }

    /// Never a guess: both lists must hold exactly the tied windows.
    func testUnequalCountsOrAnUnrankedWindowStayAmbiguous() {
        let managed = [id(1): parkedRight, id(2): parkedRight]
        let order: [pid_t: [WindowID]] = [100: [id(1), id(2)]]
        func ties(_ entries: [SnapshotCandidate], axOrder: [pid_t: [WindowID]] = order, stacking: [UInt32]) -> [WindowID: UInt32] {
            snapshotOrderTieBreaks(
                managed: managed, candidates: entries, matches: [id(1): .ambiguous, id(2): .ambiguous],
                axOrder: axOrder, stacking: stacking
            )
        }
        let three = [candidate(11, parkedRight), candidate(12, parkedRight), candidate(13, parkedRight)]
        XCTAssertEqual(ties(three, stacking: [11, 12, 13]), [:], "an extra same-size entry (an unmanaged window)")
        XCTAssertEqual(ties([candidate(11, parkedRight)], stacking: [11]), [:], "one window is not listed")
        let two = [candidate(11, parkedRight), candidate(12, parkedRight)]
        XCTAssertEqual(ties(two, stacking: [11]), [:], "an entry off the on-screen stacking (another Space)")
        XCTAssertEqual(ties(two, axOrder: [100: [id(1)]], stacking: [11, 12]), [:], "a window missing from the AX order")
        XCTAssertEqual(ties(two, axOrder: [:], stacking: [11, 12]), [:], "no AX order for the app")
        XCTAssertEqual(ties(two, axOrder: [100: [id(1), id(2), id(1)]], stacking: [11, 12]), [:], "a repeated AX entry")
    }

    /// Only ambiguous windows are tie-broken, never onto an entry another
    /// window holds, never across apps or sizes; groups of each size are
    /// ranked on their own.
    func testTheOrderTieBreakNeverSwapsOrStealsAnEntry() {
        let small = CGRect(x: 1799, y: 0, width: 600, height: 600)
        let managed = [
            id(1): parkedRight, id(2): parkedRight, id(3): parkedRight, id(4): small, id(5): small, id(6, pid: 200): parkedRight,
        ]
        let entries = [
            candidate(11, parkedRight), candidate(12, parkedRight), candidate(13, parkedRight),
            candidate(14, small), candidate(15, small), candidate(21, pid: 200, parkedRight),
        ]
        let matches: [WindowID: SnapshotMatch] = [
            id(1): .matched(12), id(2): .ambiguous, id(3): .ambiguous, id(4): .ambiguous, id(5): .ambiguous,
            id(6, pid: 200): .ambiguous,
        ]
        let ties = snapshotOrderTieBreaks(
            managed: managed, candidates: entries, matches: matches,
            axOrder: [100: [id(5), id(1), id(3), id(4), id(2)]], stacking: [15, 13, 12, 21, 14, 11]
        )
        XCTAssertEqual(ties, [id(3): 13, id(2): 11, id(5): 15, id(4): 14])
        XCTAssertNil(ties[id(1)], "a matched window keeps its entry")
        XCTAssertFalse(ties.values.contains(12), "the held entry is never taken")
        XCTAssertNil(ties[id(6, pid: 200)], "no AX order for that app")
    }

    // MARK: exclusions and backdrops

    func testExclusionsHoldAnimatedAndGioOwnedWindowsOnce() {
        let candidates = [
            candidate(11, pid: 100, a), candidate(12, pid: 100, b),
            candidate(90, pid: 999, a), candidate(91, pid: 999, b), candidate(13, pid: 300, a),
        ]
        let result = snapshotExclusions(candidates: candidates, animated: [12, 11, 12], ownPid: 999)
        XCTAssertEqual(result, [11, 12, 90, 91])
    }

    func testBackdropsOnlyForDisplaysTheWindowsTouch() {
        let displays = [
            SnapshotDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2),
            SnapshotDisplay(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), scale: 2),
        ]
        XCTAssertEqual(
            displaysNeedingBackdrop(windowFrames: [CGRect(x: 100, y: 0, width: 500, height: 500)], displays: displays),
            [1]
        )
        XCTAssertEqual(
            displaysNeedingBackdrop(windowFrames: [CGRect(x: 900, y: 0, width: 300, height: 500)], displays: displays),
            [1, 2]
        )
        XCTAssertEqual(displaysNeedingBackdrop(windowFrames: [], displays: displays), [])
    }

    // MARK: budget accounting

    func testSummaryAccountsMissesByReason() {
        let requested = [id(1), id(2), id(3), id(4), id(5), id(6)]
        let matches: [WindowID: SnapshotMatch] = [
            id(1): .matched(11), id(2): .matched(12), id(3): .matched(13), id(4): .ambiguous, id(5): .missing,
            id(6): .matched(16),
        ]
        let summary = makeSnapshotSummary(
            requested: requested, matches: matches, captured: [id(1)], failed: [id(2)], blank: [id(6)],
            backdropsRequested: 1, backdropsCaptured: 1, elapsedMilliseconds: 41.6, pixels: 1_234_567,
            reason: .typing
        )
        XCTAssertEqual(summary.windows, 6)
        XCTAssertEqual(summary.captured, 1)
        XCTAssertEqual(summary.misses[id(2)], .failed)
        XCTAssertEqual(summary.misses[id(3)], .overBudget)
        XCTAssertEqual(summary.misses[id(4)], .ambiguous)
        XCTAssertEqual(summary.misses[id(5)], .unmatched)
        XCTAssertEqual(summary.misses[id(6)], .blank)
        XCTAssertNil(summary.misses[id(1)])
        XCTAssertEqual(
            summary.logLine,
            "snapshot capture windows=6 captured=1 backdrop=true ms=42 misses=5 pixels=1234567 reason=typing"
        )
    }

    func testBackdropFlagNeedsEveryRequestedBackdrop() {
        func line(_ requested: Int, _ captured: Int) -> String {
            makeSnapshotSummary(
                requested: [], matches: [:], captured: [], failed: [],
                backdropsRequested: requested, backdropsCaptured: captured, elapsedMilliseconds: 3
            ).logLine
        }
        XCTAssertTrue(line(2, 2).contains("backdrop=true"))
        XCTAssertTrue(line(2, 1).contains("backdrop=false"))
        XCTAssertTrue(line(0, 0).contains("backdrop=false"))
    }

    func testDefaultBudgetIs45Milliseconds() {
        XCTAssertEqual(SnapshotBudget.defaultMilliseconds, 45)
    }
}
