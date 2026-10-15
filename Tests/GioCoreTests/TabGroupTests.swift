import XCTest
@testable import GioCore

/// WC-11: macOS native window tabs. Every tab is its own AX window with the
/// group's frame; a fresh `kAXWindowsAttribute` read lists only the front
/// tab. One group owns one slot, held by its front tab.
final class TabGroupTests: XCTestCase {
    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private let groupFrame = CGRect(x: 8, y: 40, width: 800, height: 600)

    private func fact(_ element: UInt64, frame: CGRect?, listed: Bool) -> TabMemberFact {
        TabMemberFact(id: id(element), frame: frame, listed: listed)
    }

    // MARK: Joining

    func testAListedArrivalJoinsTheUnlistedSiblingAtTheSameFrame() {
        let nudged = groupFrame.offsetBy(dx: 0.5, dy: -0.5)

        let target = tabGroupToJoin(
            frame: nudged, listed: true,
            siblings: [
                fact(1, frame: groupFrame.offsetBy(dx: 900, dy: 0), listed: true),
                fact(2, frame: groupFrame, listed: false),
            ]
        )

        XCTAssertEqual(target, id(2), "the new front tab took the place of the tab macOS no longer lists")
    }

    func testTwoListedWindowsAtTheSameFrameNeverMerge() {
        let target = tabGroupToJoin(
            frame: groupFrame, listed: true, siblings: [fact(1, frame: groupFrame, listed: true)]
        )

        XCTAssertNil(target, "two separate windows of one app are both listed")
    }

    func testNoJoinWithoutProofOfATab() {
        XCTAssertNil(
            tabGroupToJoin(frame: groupFrame, listed: false, siblings: [fact(1, frame: groupFrame, listed: false)]),
            "an arrival the fresh list does not show is not the front tab"
        )
        XCTAssertNil(
            tabGroupToJoin(
                frame: groupFrame, listed: true,
                siblings: [fact(1, frame: groupFrame.offsetBy(dx: 2, dy: 0), listed: false)]
            ),
            "frames more than 1 pt apart are separate windows"
        )
        XCTAssertNil(
            tabGroupToJoin(frame: groupFrame, listed: true, siblings: [fact(1, frame: nil, listed: false)]),
            "an unreadable frame proves nothing"
        )
    }

    func testJoiningMakesTheArrivalTheFrontAndTheSiblingABackgroundTab() throws {
        var book = TabGroupBook()

        let joined = try XCTUnwrap(book.join(id(2), with: id(1)))

        XCTAssertEqual(joined.handover, TabHandover(from: id(1), to: id(2)))
        let group = try XCTUnwrap(book.group(of: id(1)))
        XCTAssertEqual(group.id, joined.group)
        XCTAssertEqual(group.members, [id(1), id(2)])
        XCTAssertEqual(group.front, id(2))
        XCTAssertTrue(book.isBackground(id(1)))
        XCTAssertFalse(book.isBackground(id(2)))
    }

    func testAThirdTabJoinsTheExistingGroupThroughABackgroundMember() throws {
        var book = TabGroupBook()
        book.join(id(2), with: id(1))

        let joined = try XCTUnwrap(book.join(id(3), with: id(1)))

        XCTAssertEqual(
            joined.handover, TabHandover(from: id(2), to: id(3)), "the slot is the group's, held by its front"
        )
        XCTAssertEqual(book.group(of: id(2))?.members, [id(1), id(2), id(3)])
        XCTAssertEqual(book.group(of: id(2))?.background, [id(1), id(2)])
    }

    func testAGroupedWindowCannotJoinAgain() {
        var book = TabGroupBook()
        book.join(id(2), with: id(1))

        XCTAssertNil(book.join(id(2), with: id(1)))
        XCTAssertNil(book.join(id(1), with: id(1)))
    }

    // MARK: Switching

    func testFocusOnABackgroundTabMakesItTheFront() {
        var book = TabGroupBook()
        book.join(id(2), with: id(1))

        XCTAssertEqual(book.bringToFront(id(1)), TabHandover(from: id(2), to: id(1)))
        XCTAssertEqual(book.group(of: id(1))?.front, id(1))
        XCTAssertTrue(book.isBackground(id(2)))
        XCTAssertNil(book.bringToFront(id(1)), "the front tab switches nothing")
        XCTAssertNil(book.bringToFront(id(9)), "an ungrouped window switches nothing")
    }

    // MARK: Leaving

    func testClosingTheFrontTabHandsTheSlotToTheNextMember() {
        var book = TabGroupBook()
        book.join(id(2), with: id(1))
        book.join(id(3), with: id(1))
        book.bringToFront(id(2))

        XCTAssertEqual(book.remove([id(2)]), [TabHandover(from: id(2), to: id(3))])
        XCTAssertEqual(book.group(of: id(1))?.members, [id(1), id(3)])
        XCTAssertEqual(book.group(of: id(1))?.front, id(3))
    }

    func testClosingTheLastMemberInOrderHandsTheSlotBack() {
        var book = TabGroupBook()
        book.join(id(2), with: id(1))

        XCTAssertEqual(book.remove([id(2)]), [TabHandover(from: id(2), to: id(1))])
        XCTAssertNil(book.group(of: id(1)), "a single window is no group")
        XCTAssertFalse(book.isBackground(id(1)))
    }

    func testClosingABackgroundTabHandsNothingOver() {
        var book = TabGroupBook()
        book.join(id(2), with: id(1))
        book.join(id(3), with: id(1))

        XCTAssertEqual(book.remove([id(1)]), [])
        XCTAssertEqual(book.group(of: id(3))?.members, [id(2), id(3)])
    }

    func testRemovingAWholeGroupHandsNothingOver() {
        var book = TabGroupBook()
        book.join(id(2), with: id(1))

        XCTAssertEqual(book.remove([id(1), id(2)]), [])
        XCTAssertNil(book.group(of: id(1)))
        XCTAssertNil(book.group(of: id(2)))
    }

    func testAPreferredSurvivorTakesTheSlot() {
        var book = TabGroupBook()
        book.join(id(2), with: id(1))
        book.join(id(3), with: id(1))

        XCTAssertEqual(book.remove([id(3)], preferring: id(1)), [TabHandover(from: id(3), to: id(1))])
    }

    func testATabDraggedOutToItsOwnWindowLeaves() {
        let away = groupFrame.offsetBy(dx: 300, dy: 120)

        XCTAssertTrue(
            tabMemberLeaves(frame: away, listed: true, others: [fact(1, frame: groupFrame, listed: true)]),
            "two members on screen at different frames are two windows"
        )
        XCTAssertFalse(
            tabMemberLeaves(frame: away, listed: true, others: [fact(1, frame: groupFrame, listed: false)]),
            "only one member on screen: the group itself moved"
        )
        XCTAssertFalse(
            tabMemberLeaves(frame: away, listed: false, others: [fact(1, frame: groupFrame, listed: true)]),
            "a background tab that is not on screen did not leave"
        )
        XCTAssertFalse(
            tabMemberLeaves(frame: groupFrame, listed: true, others: [fact(1, frame: groupFrame, listed: true)]),
            "same frame: no divergence"
        )
        XCTAssertFalse(
            tabMemberLeaves(frame: away, listed: true, others: [fact(1, frame: nil, listed: true)]),
            "an unreadable frame proves nothing"
        )
    }

    // MARK: Absence from a complete scan

    func testAListedMemberKeepsItsWholeGroup() {
        var book = TabGroupBook()
        book.join(id(2), with: id(1))
        book.join(id(5), with: id(4))

        XCTAssertEqual(book.membersKept(present: [id(2), id(9)]), [id(1), id(2)])
    }

    // MARK: The slot

    /// Two columns: [1] and the stacked [2, 3]; focus on 3.
    private func manager(layout: WorkspaceLayoutKind = .scrolling) -> WorkspaceManager {
        var manager = WorkspaceManager()
        var workspace = manager.currentWorkspace()
        workspace.columns = [
            Column(id: ColumnID(1), width: 0, windows: [id(1)]),
            Column(
                id: ColumnID(2), width: 0, windows: [id(2), id(3)], focusedWindowIndex: 1,
                heightWeights: [id(3): 2]
            ),
        ]
        workspace.focusedColumn = 1
        workspace.focusedWindow = id(3)
        manager.update(workspace)
        if layout == .dwindle {
            manager.update(manager.currentWorkspace().settingLayout(.dwindle, splitRatio: 1))
        }
        return manager
    }

    func testTheNewFrontTakesTheSlotInAStackedColumn() throws {
        var manager = manager()
        let viewport = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let before = try ScrollableLayoutEngine().calculate(workspace: manager.currentWorkspace(), viewport: viewport)

        XCTAssertTrue(handOverTabSlot(TabHandover(from: id(3), to: id(4)), manager: &manager))

        let workspace = manager.currentWorkspace()
        XCTAssertEqual(workspace.columns.map(\.windows), [[id(1)], [id(2), id(4)]])
        XCTAssertEqual(workspace.focusedWindow, id(4))
        XCTAssertEqual(workspace.columns[1].focusedWindowID, id(4))
        XCTAssertEqual(workspace.columns[1].heightWeights, [id(4): 2])
        let after = try ScrollableLayoutEngine().calculate(workspace: workspace, viewport: viewport)
        XCTAssertEqual(after.frames[id(4)], before.frames[id(3)], "the front tab lands exactly where the slot was")
        XCTAssertNil(after.frames[id(3)], "the background tab is never laid out")
    }

    func testTheNewFrontTakesTheSameDwindleLeaf() {
        var manager = manager(layout: .dwindle)
        let tree = dwindleTreeSummary(manager.currentWorkspace().dwindle)

        XCTAssertTrue(handOverTabSlot(TabHandover(from: id(2), to: id(4)), manager: &manager))

        XCTAssertEqual(
            dwindleTreeSummary(manager.currentWorkspace().dwindle),
            tree.replacingOccurrences(of: "10:2", with: "10:4")
        )
        XCTAssertEqual(manager.currentWorkspace().windows, [id(1), id(4), id(3)])
    }

    func testAHandoverWithoutASlotChangesNothing() {
        var manager = manager()
        let before = manager.currentWorkspace()

        XCTAssertFalse(handOverTabSlot(TabHandover(from: id(9), to: id(4)), manager: &manager))
        XCTAssertEqual(manager.currentWorkspace(), before)
    }
}
