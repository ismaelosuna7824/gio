import CoreGraphics
import Foundation
import XCTest
@testable import GioCore

/// MM-04: the live arrangement of 2026-10-08 (read from `NSScreen`): the
/// built-in primary display and an external display left of it whose bottom
/// is 224 pt lower and whose top is 47 pt higher. Cocoa coordinates.
enum LiveArrangement {
    static let builtIn = DisplayID(1)
    static let external = DisplayID(3)
    static let builtInFrame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    static let builtInVisible = CGRect(x: 0, y: 0, width: 1800, height: 1130)
    static let externalFrame = CGRect(x: -2160, y: -224, width: 2160, height: 1440)
    static let externalVisible = externalFrame
    /// The external in AX/WindowServer space (origin top-left of the
    /// primary, y down): its top edge is y = 1169 - 1216 = -47.
    static let externalAX = CGRect(x: -2160, y: -47, width: 2160, height: 1440)
    static let primaryHeight: CGFloat = 1169

    static var frames: [DisplayID: CGRect] {
        [builtIn: builtInFrame, external: externalFrame]
    }
}

final class MultiDisplayRepairTests: XCTestCase {
    private typealias Live = LiveArrangement

    private func workspace(columns count: Int, focus: Int, spec: ColumnWidthSpec = .standard) -> Workspace {
        var workspace = Workspace(id: WorkspaceID(1))
        for index in 0..<count {
            let id = WindowID(pid: pid_t(100 + index), elementID: UInt64(index + 1))
            workspace.columns.append(Column(id: ColumnID(UInt64(index + 1)), width: 0, windows: [id], widthSpec: spec))
        }
        workspace.focusedColumn = focus
        workspace.focusedWindow = workspace.columns[focus].windows[0]
        return workspace
    }

    private func id(_ index: Int) -> WindowID {
        WindowID(pid: pid_t(100 + index), elementID: UInt64(index + 1))
    }

    private let engine = ScrollableLayoutEngine(config: LayoutConfig(padding: 8, gap: 8))

    // MARK: Flip (verified: not the defect)

    func testTheFlipUsesThePrimaryHeightAndKeepsExternalFramesOnTheExternal() {
        // The WindowServer flip is the AX flip (same formula, Core's copy).
        XCTAssertEqual(
            cocoaFrame(fromWindowServer: Live.externalFrame, displayHeight: Live.primaryHeight), Live.externalAX
        )
        // The live `reconcile failure` frames are Cocoa (the actuator logs
        // the frame it was asked for, before the flip): flipped with the
        // primary height they sit inside the external's AX bounds.
        let requested = CGRect(x: -1076, y: -216, width: 1068, height: 1394)
        let ax = cocoaFrame(fromWindowServer: requested, displayHeight: Live.primaryHeight)
        XCTAssertEqual(ax, CGRect(x: -1076, y: -9, width: 1068, height: 1394))
        XCTAssertTrue(Live.externalAX.contains(ax))
    }

    // MARK: Peeking columns never straddle (symptom 1)

    func testAColumnPeekingOverASharedEdgeParksOffItsDisplaysFreeSide() {
        // The live `requested=(-538,-216,1068,1394)`: the external's right
        // neighbour of a centered column, half on the built-in.
        let straddling = CGRect(x: -538, y: -216, width: 1068, height: 1424)
        let plan = planParking(
            frames: [id(2): straddling], viewport: Live.externalVisible, display: Live.externalFrame,
            otherDisplays: [Live.builtInFrame]
        )
        XCTAssertNil(plan.visible[id(2)])
        let parked = try? XCTUnwrap(plan.parked[id(2)])
        XCTAssertEqual(parked?.edge, .left)
        XCTAssertEqual(parked?.farSide, true)
        XCTAssertFalse(parked.map { $0.frame.intersects(Live.builtInFrame) } ?? true)
    }

    func testTheBuiltInsLeftPeekNeverReachesTheExternal() {
        let peek = CGRect(x: -440, y: 8, width: 888, height: 1114)
        let plan = planParking(
            frames: [id(0): peek], viewport: Live.builtInVisible, display: Live.builtInFrame,
            otherDisplays: [Live.externalFrame]
        )
        XCTAssertNil(plan.visible[id(0)])
        XCTAssertEqual(plan.parked[id(0)]?.edge, .right)
        XCTAssertEqual(plan.parked[id(0)]?.farSide, true)
        XCTAssertFalse(plan.parked[id(0)].map { $0.frame.intersects(Live.externalFrame) } ?? true)
    }

    func testAPeekTowardsNoDisplayStaysVisible() {
        let rightPeek = CGRect(x: 1352, y: 8, width: 888, height: 1114)
        let plan = planParking(
            frames: [id(2): rightPeek], viewport: Live.builtInVisible, display: Live.builtInFrame,
            otherDisplays: [Live.externalFrame]
        )
        XCTAssertEqual(plan.visible[id(2)], rightPeek)
        // One display: an off-viewport column parks on its own side, never "far".
        let single = planParking(
            frames: [id(0): CGRect(x: -900, y: 8, width: 888, height: 1114)],
            viewport: Live.builtInVisible, display: Live.builtInFrame, otherDisplays: []
        )
        XCTAssertEqual(single.parked[id(0)]?.edge, .left)
        XCTAssertEqual(single.parked[id(0)]?.farSide, false)
    }

    /// Every visible frame of a display plan sits on its display; no frame
    /// (visible or parked) overlaps another display.
    private func assertConfined(
        _ plan: DisplayLayoutPlan, display: CGRect, other: CGRect, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for (window, frame) in plan.plan.visible {
            XCTAssertFalse(frame.intersects(other), "\(label) \(window.pid) visible \(frame)", file: file, line: line)
        }
        for (window, target) in plan.plan.parked {
            XCTAssertFalse(target.frame.intersects(other), "\(label) \(window.pid) parked \(target.frame)", file: file, line: line)
        }
    }

    func testTheExternalStripStaysInsideTheExternalsAXBounds() throws {
        for focus in 0..<4 {
            let planned = try planDisplayLayout(
                workspace: workspace(columns: 4, focus: focus), modes: [:], engine: engine,
                viewport: Live.externalVisible, display: Live.externalFrame, otherDisplays: [Live.builtInFrame],
                centering: CenterRequest(mode: .always, previouslyFocused: nil)
            )
            assertConfined(planned, display: Live.externalFrame, other: Live.builtInFrame, "focus \(focus)")
            for frame in planned.plan.visible.values {
                // The AX request: inside the external's AX rows, never past
                // its right edge (the built-in). A peek past its free left
                // edge is off every display, as on a single display.
                let ax = cocoaFrame(fromWindowServer: frame, displayHeight: Live.primaryHeight)
                XCTAssertLessThanOrEqual(ax.maxX, Live.externalAX.maxX, "focus \(focus) \(frame)")
                XCTAssertGreaterThanOrEqual(ax.minY, Live.externalAX.minY)
                XCTAssertLessThanOrEqual(ax.maxY, Live.externalAX.maxY)
            }
        }
    }

    func testTheBuiltInStripKeepsItsRightNeighbourAndNeverReachesTheExternal() throws {
        // Symptom 2: three half-width columns, the middle one centered.
        let planned = try planDisplayLayout(
            workspace: workspace(columns: 3, focus: 1), modes: [:], engine: engine,
            viewport: Live.builtInVisible, display: Live.builtInFrame, otherDisplays: [Live.externalFrame],
            centering: CenterRequest(mode: .always, previouslyFocused: nil)
        )
        assertConfined(planned, display: Live.builtInFrame, other: Live.externalFrame, "built-in")
        XCTAssertNotNil(planned.plan.visible[id(1)], "the focused column")
        XCTAssertNotNil(planned.plan.visible[id(2)], "the right neighbour peeks (nothing lies right of the built-in)")
    }

    func testAColumnWiderThanTheRoomAtTheEdgeNeverStraddles() throws {
        // Columns wider than the room left between the centered column and
        // the shared edge: whatever is focused, nothing crosses the edge.
        for focus in 0..<3 {
            for mode in [CenterFocusedColumnMode.always, .never] {
                let external = try planDisplayLayout(
                    workspace: workspace(columns: 3, focus: focus, spec: .points(1500)), modes: [:], engine: engine,
                    viewport: Live.externalVisible, display: Live.externalFrame, otherDisplays: [Live.builtInFrame],
                    centering: CenterRequest(mode: mode, previouslyFocused: nil)
                )
                assertConfined(external, display: Live.externalFrame, other: Live.builtInFrame, "external \(focus) \(mode)")
                let builtIn = try planDisplayLayout(
                    workspace: workspace(columns: 3, focus: focus, spec: .points(1300)), modes: [:], engine: engine,
                    viewport: Live.builtInVisible, display: Live.builtInFrame, otherDisplays: [Live.externalFrame],
                    centering: CenterRequest(mode: mode, previouslyFocused: nil)
                )
                assertConfined(builtIn, display: Live.builtInFrame, other: Live.externalFrame, "built-in \(focus) \(mode)")
            }
        }
    }

    func testTheFocusedColumnStaysVisibleEvenWiderThanItsDisplay() throws {
        // Niri rule: the focused column is shown. One wider than the
        // external cannot avoid the built-in; it is kept, the rest parks.
        let planned = try planDisplayLayout(
            workspace: workspace(columns: 2, focus: 0, spec: .points(2500)), modes: [:], engine: engine,
            viewport: Live.externalVisible, display: Live.externalFrame, otherDisplays: [Live.builtInFrame]
        )
        XCTAssertNotNil(planned.plan.visible[id(0)])
        XCTAssertNotNil(planned.plan.parked[id(1)])
    }

    // MARK: Empty columns at a shared edge (MM-08)

    /// The live strip of 2026-10-14 (screenshot): 888 pt columns, WhatsApp's
    /// learned 970, focus moved right onto it.
    private func liveStrip(focus: Int, offset: CGFloat) -> Workspace {
        var strip = workspace(columns: 5, focus: focus, spec: .points(888))
        strip.columns[3].widthSpec = .points(970)
        strip.viewportOffset = offset
        return strip
    }

    func testAFocusedColumnNeverLeavesAnEmptyGapAtTheSharedEdge() throws {
        // Minimal reveal: WhatsApp flush right at 822, its left neighbour at
        // -74..814 straddles the external and parks: 814 pt of empty screen
        // (the screenshot). Flush left instead, the right neighbour peeks over
        // the free right edge.
        let planned = try planDisplayLayout(
            workspace: liveStrip(focus: 3, offset: 896), modes: [:], engine: engine,
            viewport: Live.builtInVisible, display: Live.builtInFrame, otherDisplays: [Live.externalFrame]
        )
        assertConfined(planned, display: Live.builtInFrame, other: Live.externalFrame, "built-in")
        XCTAssertEqual(planned.plan.visible[id(3)]?.minX, 8)
        XCTAssertEqual(planned.plan.visible[id(4)]?.minX, 986, "the right neighbour peeks over the free edge")
        XCTAssertNotNil(planned.plan.parked[id(2)])
        // Stable: the next (passive) pass keeps the offset.
        let again = try planDisplayLayout(
            workspace: planned.workspace, modes: [:], engine: engine,
            viewport: Live.builtInVisible, display: Live.builtInFrame, otherDisplays: [Live.externalFrame]
        )
        XCTAssertEqual(again.workspace.viewportOffset, planned.workspace.viewportOffset)
        XCTAssertEqual(again.plan, planned.plan)
    }

    func testOnOneDisplayTheMinimalRevealStaysWithItsLeftPeek() throws {
        let planned = try planDisplayLayout(
            workspace: liveStrip(focus: 3, offset: 896), modes: [:], engine: engine,
            viewport: Live.builtInVisible, display: Live.builtInFrame, otherDisplays: []
        )
        XCTAssertEqual(planned.plan.visible[id(3)]?.minX, 822)
        XCTAssertEqual(planned.plan.visible[id(2)]?.minX, -74)
    }

    func testAStripRightOfItsSharedEdgeAlignsTheFocusedColumnRight() throws {
        // The external: the built-in shares its right edge. Moving left onto
        // column 1, the minimal reveal leaves column 2 across that edge;
        // flush right, column 0 peeks over the free left edge instead.
        let external = CGRect(x: 0, y: 0, width: 2160, height: 1410)
        let builtIn = CGRect(x: 2160, y: 0, width: 1800, height: 1169)
        var strip = workspace(columns: 4, focus: 1, spec: .points(1400))
        strip.viewportOffset = 2816
        let planned = try planDisplayLayout(
            workspace: strip, modes: [:], engine: engine,
            viewport: external, display: external, otherDisplays: [builtIn]
        )
        assertConfined(planned, display: external, other: builtIn, "external")
        XCTAssertEqual(planned.plan.visible[id(1)]?.maxX, 2152)
        XCTAssertNotNil(planned.plan.visible[id(0)], "the left neighbour peeks over the free edge")
        XCTAssertNotNil(planned.plan.parked[id(2)])
    }

    func testCenteringModesKeepTheirOffset() throws {
        let parsed = try parseGioConfig("[layout]\ncenter-focused-column = \"always\"\n").get().0
        XCTAssertEqual(parsed.makeLayoutConfig().centerFocusedColumn, .always)
        XCTAssertEqual(GioConfig().makeLayoutConfig().centerFocusedColumn, .never)
        let config = LayoutConfig(padding: 8, gap: 8, centerFocusedColumn: .always)
        let centered = ScrollableLayoutEngine(config: config)
        let request = CenterRequest(mode: .always, previouslyFocused: id(2))
        let planned = try planDisplayLayout(
            workspace: liveStrip(focus: 3, offset: 896), modes: [:], engine: centered,
            viewport: Live.builtInVisible, display: Live.builtInFrame, otherDisplays: [Live.externalFrame],
            centering: request
        )
        let frame = try XCTUnwrap(planned.plan.visible[id(3)])
        XCTAssertEqual(frame.midX, Live.builtInVisible.midX, accuracy: 1)
        // A passive pass (no centering request) leaves the centered strip alone.
        let passive = try planDisplayLayout(
            workspace: planned.workspace, modes: [:], engine: centered,
            viewport: Live.builtInVisible, display: Live.builtInFrame, otherDisplays: [Live.externalFrame]
        )
        XCTAssertEqual(passive.workspace.viewportOffset, planned.workspace.viewportOffset)
    }

    // MARK: Display numbers

    func testDisplayNumbersPutThePrimaryFirstThenPositionOrder() {
        XCTAssertEqual(displaysByNumber(Live.frames), [Live.builtIn, Live.external])
        let right = DisplayID(7)
        var three = Live.frames
        three[right] = CGRect(x: 1800, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(displaysByNumber(three), [Live.builtIn, Live.external, right])
        XCTAssertEqual(displaysByNumber([:]), [])
    }

    // MARK: Overview display (symptom 3)

    func testTheOverviewOpensOnTheFocusedWindowsDisplayElseUnderTheCursor() {
        let onExternal = CGRect(x: -1076, y: -216, width: 1068, height: 1424)
        XCTAssertEqual(
            overviewDisplay(
                focusedWindowFrame: onExternal, cursor: CGPoint(x: 900, y: 500),
                displays: Live.frames, focusedDisplay: Live.builtIn
            ).map { [$0.display.rawValue: $0.reason] },
            [Live.external.rawValue: .focusedWindow]
        )
        // A straddling window counts for the display holding most of it.
        XCTAssertEqual(
            overviewDisplay(
                focusedWindowFrame: CGRect(x: -300, y: 100, width: 1068, height: 900), cursor: nil,
                displays: Live.frames, focusedDisplay: Live.external
            )?.display,
            Live.builtIn
        )
        XCTAssertEqual(
            overviewDisplay(
                focusedWindowFrame: nil, cursor: CGPoint(x: -1000, y: 900),
                displays: Live.frames, focusedDisplay: Live.builtIn
            ).map { [$0.display.rawValue: $0.reason] },
            [Live.external.rawValue: .cursor]
        )
        XCTAssertEqual(
            overviewDisplay(
                focusedWindowFrame: nil, cursor: CGPoint(x: 5000, y: 5000),
                displays: Live.frames, focusedDisplay: Live.builtIn
            ).map { [$0.display.rawValue: $0.reason] },
            [Live.builtIn.rawValue: .focusedDisplay]
        )
        XCTAssertNil(overviewDisplay(focusedWindowFrame: nil, cursor: nil, displays: [:], focusedDisplay: nil))
    }

    // MARK: Display log lines

    func testDisplayConfigurationLogLines() {
        let lines = displayConfigurationLog([
            DisplayLogEntry(
                id: Live.external, frame: Live.externalFrame, visibleFrame: Live.externalVisible,
                scale: 1, refreshRate: 60, isPrimary: false, number: 2,
                shownWorkspace: WorkspaceID(4), stack: [WorkspaceID(4), WorkspaceID(9)]
            ),
            DisplayLogEntry(
                id: Live.builtIn, frame: Live.builtInFrame, visibleFrame: Live.builtInVisible,
                scale: 2, refreshRate: 120, isPrimary: true, number: 1,
                shownWorkspace: WorkspaceID(2), stack: [WorkspaceID(2), WorkspaceID(3), WorkspaceID(5)]
            ),
        ])
        XCTAssertEqual(lines, [
            "displays count=2",
            "display index=1 id=3 frame=(-2160,-224,2160,1440) visible=(-2160,-224,2160,1440) scale=1 hz=60"
                + " primary=false number=2 shown=4 stack=4,9",
            "display index=2 id=1 frame=(0,0,1800,1169) visible=(0,0,1800,1130) scale=2 hz=120"
                + " primary=true number=1 shown=2 stack=2,3,5",
        ])
        XCTAssertEqual(
            displayFlipLogLine(primaryHeight: 1169, primary: Live.builtIn),
            "display flip primaryHeight=1169 primary=1"
        )
    }

    // MARK: Hot-plug

    func testADisplayChangeLandsTheNextPassInstantly() {
        var gate = InstantPlacementGate(armed: nil)
        gate.arm(.displays)
        XCTAssertEqual(gate.decide(requested: true), .instant(.displays))
        XCTAssertEqual(instantPlacementLogLine(.displays), "layout instant reason=displays")
    }

    // MARK: move-window-to-display (menu bar, launcher, CLI)

    func testMoveWindowToDisplayParses() {
        XCTAssertEqual(parseCLICommand(["move-window-to-display", "2"]), .success(.moveWindowToDisplay(2)))
        XCTAssertEqual(
            parseCLICommand(["move-window-to-display"]),
            .failure(.missingArgument(name: "display number", command: "move-window-to-display"))
        )
        XCTAssertEqual(
            parseCLICommand(["move-window-to-display", "0"]),
            .failure(.missingArgument(name: "display number", command: "move-window-to-display"))
        )
        XCTAssertTrue(CLICommand.moveWindowToDisplay(1).carriesFocusIntent)
        XCTAssertTrue(cliUsage().contains("gio move-window-to-display N"))
    }

    func testMoveWindowToDisplayMovesTheFocusedWindowByDisplayNumber() {
        var session = CommandSession()
        session.manager.syncDisplays([Live.external, Live.builtIn], main: Live.builtIn)
        var workspace = session.manager.currentWorkspace()
        let window = id(0)
        workspace.columns = [Column(id: ColumnID(1), width: 0, windows: [window])]
        workspace.focusedWindow = window
        session.manager.update(workspace)

        XCTAssertEqual(dispatch(.moveWindowToDisplay(2), session: &session), "moved window to display 2")
        XCTAssertEqual(session.manager.focusedDisplay, Live.external)
        XCTAssertEqual(session.manager.currentWorkspace().focusedWindow, window)
        XCTAssertEqual(dispatch(.moveWindowToDisplay(2), session: &session), "move unchanged (already on display 2)")
        XCTAssertEqual(dispatch(.moveWindowToDisplay(5), session: &session), "no display 5")
    }
}
