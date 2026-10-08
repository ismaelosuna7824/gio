import XCTest
@testable import GioCore

/// NW-02: named workspaces are persistent members of their display's stack,
/// ordered first in config order; dynamic workspaces follow with the NF-02
/// rules; reloads never lose a window.
final class NamedWorkspaceManagerTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func defs(_ names: String...) -> [WorkspaceDefinition] {
        names.map { WorkspaceDefinition(name: $0) }
    }

    /// Put window `n` in a new last column of the current workspace, focused.
    private func put(_ manager: inout WorkspaceManager, _ n: UInt64) {
        var workspace = manager.currentWorkspace()
        workspace.columns.append(Column(id: ColumnID(n), width: 300, windows: [id(n)]))
        workspace.focusedColumn = workspace.columns.count - 1
        workspace.focusedWindow = id(n)
        manager.update(workspace)
    }

    private func put(_ manager: inout WorkspaceManager, _ n: UInt64, in workspaceID: WorkspaceID) {
        var workspace = manager.workspace(id: workspaceID)!
        workspace.columns.append(Column(id: ColumnID(n), width: 300, windows: [id(n)]))
        manager.update(workspace)
    }

    private func windows(_ manager: WorkspaceManager) -> Set<WindowID> {
        Set(manager.allWorkspaces.flatMap { $0.columns.flatMap(\.windows) })
    }

    private func names(_ manager: WorkspaceManager, on display: DisplayID = WorkspaceManager.placeholderDisplay) -> [String?] {
        manager.stack(on: display).map(\.name)
    }

    /// NF-02 invariants adapted to named workspaces: named ones first in
    /// config order (per display), a trailing empty dynamic spare, no empty
    /// inactive dynamic workspace, unique ids, the active one in the stack.
    private func assertInvariants(
        _ manager: WorkspaceManager, file: StaticString = #filePath, line: UInt = #line
    ) {
        for display in manager.displayIDs {
            let stack = manager.stack(on: display)
            XCTAssertFalse(stack.isEmpty, "empty stack", file: file, line: line)
            XCTAssertNil(stack.last?.name, "spare must be dynamic", file: file, line: line)
            XCTAssertTrue(stack.last?.columns.isEmpty ?? false, "no trailing empty workspace", file: file, line: line)
            let namedPrefix = stack.prefix { $0.name != nil }
            XCTAssertEqual(
                stack.filter { $0.name != nil }.count, namedPrefix.count, "named not first", file: file, line: line
            )
            let active = manager.activeID(on: display)
            for workspace in stack.dropLast() where workspace.columns.isEmpty && workspace.name == nil {
                XCTAssertEqual(workspace.id, active, "empty inactive workspace kept", file: file, line: line)
            }
            XCTAssertEqual(Set(stack.map(\.id)).count, stack.count, "duplicate ids", file: file, line: line)
            XCTAssertNotNil(active.flatMap { a in stack.first { $0.id == a } }, "active not in stack", file: file, line: line)
        }
        let allNames = manager.allWorkspaces.compactMap(\.name)
        XCTAssertEqual(allNames.sorted(), manager.namedDefinitions.map(\.name).sorted(), file: file, line: line)
    }

    func testEmptyNamedWorkspacesExistFirstAndPersist() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code", "Chat"))
        XCTAssertEqual(names(manager), ["Code", "Chat", nil])
        assertInvariants(manager)
        // Leaving an empty named workspace keeps it.
        XCTAssertEqual(manager.current, 1)
        XCTAssertTrue(manager.focusDown())
        XCTAssertTrue(manager.focusDown())
        XCTAssertEqual(names(manager), ["Code", "Chat", nil])
        assertInvariants(manager)
    }

    func testStartupWindowsInTheFirstWorkspaceStayPutWhenNamesArrive() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        manager.applyNamedWorkspaces(defs("Code"))
        // The dynamic workspace holding window 1 follows the named ones.
        XCTAssertEqual(names(manager), ["Code", nil, nil])
        XCTAssertEqual(manager.stack(on: WorkspaceManager.placeholderDisplay)[1].columns.first?.windows, [id(1)])
        XCTAssertEqual(manager.currentWorkspace().columns.first?.windows, [id(1)], "the active workspace is kept")
        XCTAssertEqual(manager.current, 2)
        assertInvariants(manager)
    }

    func testIndexJumpsCountNamedWorkspacesFirst() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code", "Chat"))
        manager.switchTo(2)
        XCTAssertEqual(manager.currentWorkspace().name, "Chat")
        manager.switchTo(9)
        XCTAssertNil(manager.currentWorkspace().name)
        XCTAssertEqual(manager.current, 3)
        XCTAssertEqual(manager.ruleTarget(1), manager.namedWorkspaceID("Code"))
    }

    func testDynamicWorkspacesFollowNamedOnesWithTheUsualRules() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code"))
        manager.switchTo(2)
        put(&manager, 1)
        XCTAssertEqual(names(manager), ["Code", nil, nil])
        manager.moveWindowDown(id(1))
        // The emptied dynamic source disappears; the named one stays.
        XCTAssertEqual(names(manager), ["Code", nil, nil])
        assertInvariants(manager)
    }

    func testMovingIntoANamedWorkspaceAndBack() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code"))
        manager.switchTo(2)
        put(&manager, 1)
        XCTAssertTrue(manager.moveWindowUp(id(1)))
        XCTAssertEqual(manager.currentWorkspace().name, "Code")
        XCTAssertEqual(names(manager), ["Code", nil])
        XCTAssertTrue(manager.moveWindowDown(id(1)))
        XCTAssertEqual(names(manager), ["Code", nil, nil])
        assertInvariants(manager)
    }

    func testRemovedNamedWorkspaceBecomesDynamicAndKeepsItsWindows() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code", "Chat"))
        put(&manager, 1, in: manager.namedWorkspaceID("Chat")!)
        let chat = manager.namedWorkspaceID("Chat")!
        manager.applyNamedWorkspaces(defs("Code"))
        XCTAssertNil(manager.namedWorkspaceID("Chat"))
        XCTAssertEqual(manager.workspace(id: chat)?.name, nil)
        XCTAssertEqual(windows(manager), [id(1)])
        XCTAssertEqual(names(manager), ["Code", nil, nil])
        assertInvariants(manager)
    }

    func testRemovedEmptyNamedWorkspaceDisappears() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code", "Chat"))
        manager.applyNamedWorkspaces(defs("Code"))
        XCTAssertEqual(names(manager), ["Code", nil])
        assertInvariants(manager)
    }

    func testRenameInTheSameSlotKeepsTheWorkspace() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code", "Chat"))
        let chat = manager.namedWorkspaceID("Chat")!
        put(&manager, 1, in: chat)
        manager.applyNamedWorkspaces(defs("Code", "Talk"))
        XCTAssertEqual(manager.namedWorkspaceID("Talk"), chat)
        XCTAssertEqual(names(manager), ["Code", "Talk", nil])
        XCTAssertEqual(windows(manager), [id(1)])
    }

    func testReorderMatchesByName() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code", "Chat"))
        let code = manager.namedWorkspaceID("Code")!
        let chat = manager.namedWorkspaceID("Chat")!
        manager.applyNamedWorkspaces(defs("Chat", "Code"))
        XCTAssertEqual(names(manager), ["Chat", "Code", nil])
        XCTAssertEqual(manager.namedWorkspaceID("Code"), code)
        XCTAssertEqual(manager.namedWorkspaceID("Chat"), chat)
    }

    func testAddingANameKeepsTheActiveWorkspace() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code"))
        manager.switchTo(2)
        put(&manager, 1)
        let active = manager.currentID
        manager.applyNamedWorkspaces(defs("Code", "Chat"))
        XCTAssertEqual(manager.currentID, active)
        XCTAssertEqual(names(manager), ["Code", "Chat", nil, nil])
        assertInvariants(manager)
    }

    func testDisplayAssignmentWithFallbackToMain() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces([
            WorkspaceDefinition(name: "Code"),
            WorkspaceDefinition(name: "Chat", display: .index(2)),
            WorkspaceDefinition(name: "Web", display: .index(3)),
        ])
        let left = DisplayID(5), right = DisplayID(3)
        // Display 5 is the main one even though 3 sorts first.
        manager.syncDisplays([right, left], main: left)
        XCTAssertEqual(names(manager, on: left), ["Code", "Web", nil])
        XCTAssertEqual(names(manager, on: right), ["Chat", nil])
        assertInvariants(manager)

        // Unplugging display 2 brings its named workspace home (with windows).
        put(&manager, 1, in: manager.namedWorkspaceID("Chat")!)
        manager.syncDisplays([left], main: left)
        XCTAssertEqual(names(manager, on: left), ["Code", "Chat", "Web", nil])
        XCTAssertEqual(windows(manager), [id(1)])
        assertInvariants(manager)

        // Plugging it back sends it there again.
        manager.syncDisplays([left, right], main: left)
        XCTAssertEqual(names(manager, on: left), ["Code", "Web", nil])
        XCTAssertEqual(names(manager, on: right), ["Chat", nil])
        XCTAssertEqual(windows(manager), [id(1)])
        assertInvariants(manager)
    }

    // MARK: - Monitor actions (MM-02)

    func testNamedWorkspacesStayOnTheirDisplayButTheirColumnsMove() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.applyNamedWorkspaces(defs("Code"))
        manager.syncDisplays([a, b], main: a)
        XCTAssertEqual(manager.currentWorkspace().name, "Code")
        put(&manager, 1)
        let before = manager
        XCTAssertFalse(manager.moveWorkspace(toDisplay: b), "a named workspace lives where config puts it")
        XCTAssertEqual(manager, before)
        XCTAssertTrue(manager.moveColumn(toDisplay: b))
        XCTAssertEqual(names(manager, on: a), ["Code", nil], "the emptied named workspace persists")
        XCTAssertEqual(manager.currentWorkspace().columns.first?.windows, [id(1)])
        assertInvariants(manager)
    }

    func testAWorkspaceMovedOntoANamedStackLandsAfterTheNamedOnes() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.applyNamedWorkspaces([
            WorkspaceDefinition(name: "Code", display: .index(2)),
            WorkspaceDefinition(name: "Chat", display: .index(2)),
        ])
        manager.syncDisplays([a, b], main: a)
        XCTAssertEqual(names(manager, on: b), ["Code", "Chat", nil])
        XCTAssertEqual(manager.activeID(on: b), manager.namedWorkspaceID("Code"))
        put(&manager, 1)
        let moving = manager.currentID
        XCTAssertTrue(manager.moveWorkspace(toDisplay: b))
        XCTAssertEqual(names(manager, on: b), ["Code", "Chat", nil, nil])
        XCTAssertEqual(manager.stack(on: b)[2].id, moving)
        XCTAssertEqual(manager.currentID, moving)
        XCTAssertEqual(manager.current, 3)
        assertInvariants(manager)
        manager.syncDisplays([a, b], main: a)
        XCTAssertEqual(manager.stack(on: b)[2].id, moving, "a resync keeps it on its new display")
        assertInvariants(manager)
    }

    func testSummariesCarryNamesIconsAndColors() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces([WorkspaceDefinition(name: "Code", icon: "hammer", color: "#ff0000")])
        let entries = manager.stackSummaries()[0].workspaces
        XCTAssertEqual(entries[0].name, "Code")
        XCTAssertEqual(entries[0].icon, "hammer")
        XCTAssertEqual(entries[0].color, "#ff0000")
        XCTAssertNil(entries[1].name)
        XCTAssertEqual(entries[1], WorkspaceEntry(index: 2, windows: 0, columns: 0, isActive: false))
    }

    func testUpdateCannotRenameAWorkspace() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code"))
        var workspace = manager.currentWorkspace()
        workspace.name = "Hacked"
        manager.update(workspace)
        XCTAssertEqual(manager.currentWorkspace().name, "Code")
    }

    // MARK: - Session config

    func testCommandSessionAppliesNamedWorkspacesFromConfig() {
        var config = defaultGioConfig()
        config.workspaces = defs("Code")
        var session = CommandSession(config: config)
        XCTAssertEqual(session.manager.currentWorkspace().name, "Code")
        session.config.workspaces = defs("Code", "Chat")
        XCTAssertNotNil(session.manager.namedWorkspaceID("Chat"))
    }

    func testListWorkspacesAndStatusShowNames() {
        var config = defaultGioConfig()
        config.workspaces = defs("Code")
        var session = CommandSession(config: config)
        let listing = dispatch(.listWorkspaces, session: &session)
        XCTAssertTrue(listing.contains("*1 columns=0 windows=0 name=Code"), listing)
        XCTAssertTrue(listing.contains(" 2 columns=0 windows=0"), listing)
        let status = queryStatus(session: session)
        XCTAssertTrue(status.contains("\"name\":\"Code\""), status)
    }

    // MARK: - Routing decisions

    func testFollowPolicy() {
        XCTAssertTrue(shouldFollowArrival(.always, windowPID: 7, frontmostPID: 8))
        XCTAssertFalse(shouldFollowArrival(.never, windowPID: 7, frontmostPID: 7))
        XCTAssertTrue(shouldFollowArrival(.whenActive, windowPID: 7, frontmostPID: 7))
        XCTAssertFalse(shouldFollowArrival(.whenActive, windowPID: 7, frontmostPID: 8))
        XCTAssertFalse(shouldFollowArrival(.whenActive, windowPID: 7, frontmostPID: nil))
    }

    func testArrivalDestinationPrefersTheNamedWorkspace() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code", "Chat"))
        let chat = manager.namedWorkspaceID("Chat")!
        XCTAssertEqual(
            manager.arrivalDestination(RuleOutcome(workspace: 1, openOnWorkspace: "Chat")), chat
        )
        XCTAssertEqual(manager.arrivalDestination(RuleOutcome(workspace: 2)), chat)
        XCTAssertEqual(manager.arrivalDestination(RuleOutcome(openOnWorkspace: "Gone")), manager.currentID)
        XCTAssertEqual(manager.arrivalDestination(.none), manager.currentID)
    }

    func testAStartupWindowLandsOnItsDisplayUnlessARuleRoutesIt() {
        // MM-01: a startup window goes to the shown workspace of the display
        // it sits on; named and indexed rules keep their precedence.
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(1), DisplayID(2))
        manager.syncDisplays([a, b], main: a)
        manager.applyNamedWorkspaces(defs("Code"))
        let code = manager.namedWorkspaceID("Code")!
        let onB = manager.activeID(on: b)!
        XCTAssertEqual(manager.arrivalDestination(.none, onDisplay: b), onB)
        XCTAssertEqual(manager.arrivalDestination(RuleOutcome(openOnWorkspace: "Code"), onDisplay: b), code)
        XCTAssertEqual(manager.arrivalDestination(RuleOutcome(workspace: 1), onDisplay: b), manager.ruleTarget(1))
        XCTAssertEqual(manager.arrivalDestination(.none, onDisplay: DisplayID(9)), manager.currentID)
        XCTAssertEqual(manager.arrivalDestination(.none, onDisplay: nil), manager.currentID)
    }

    func testReloadKeepsBundleRuleFloats() {
        let window = ManagedWindow(
            id: id(1), pid: 10, application: "Code", bundleID: "com.microsoft.VSCode", title: "",
            frame: .zero, mode: .floating, floatReason: .rule
        )
        let rules = [WindowRule(app: "", bundleID: "com.microsoft.VSCode", mode: .floating)]
        XCTAssertEqual(reevaluateRules(rules, windows: [window]), [])
    }

    // MARK: - Property

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// Random operations, including reloads with shifting name lists and
    /// display changes, keep the invariants and never lose a window.
    func testRandomOperationsWithNamesKeepInvariants() {
        var rng = SeededGenerator(state: 0xBADC0DE)
        var manager = WorkspaceManager()
        var live = Set<WindowID>()
        var nextWindow: UInt64 = 1
        let displays = [DisplayID(21), DisplayID(22)]
        let pool = ["A", "B", "C", "D"]
        manager.syncDisplays(displays, main: displays[0])
        for step in 0..<3000 {
            switch Int.random(in: 0..<15, using: &rng) {
            case 0, 1:
                put(&manager, nextWindow)
                live.insert(id(nextWindow))
                nextWindow += 1
            case 2: manager.focusDown()
            case 3: manager.focusUp()
            case 4:
                if let focused = manager.currentWorkspace().focusedWindow {
                    manager.moveWindowDown(focused)
                }
            case 5:
                if let focused = manager.currentWorkspace().focusedWindow {
                    manager.moveWindowUp(focused)
                }
            case 6:
                manager.switchTo(Int.random(in: 0...10, using: &rng))
            case 7:
                if let focused = manager.currentWorkspace().focusedWindow {
                    manager.moveWindow(focused, to: Int.random(in: 0...10, using: &rng))
                }
            case 8:
                if let victim = live.randomElement(using: &rng) {
                    for var workspace in manager.allWorkspaces
                    where workspace.columns.contains(where: { $0.windows.contains(victim) }) {
                        workspace.stripWindows([victim])
                        manager.update(workspace)
                    }
                    live.remove(victim)
                }
            case 9:
                let chosen = pool.shuffled(using: &rng).prefix(Int.random(in: 0...3, using: &rng))
                manager.applyNamedWorkspaces(chosen.map {
                    WorkspaceDefinition(name: $0, display: Bool.random(using: &rng) ? .index(2) : nil)
                })
            case 10:
                manager.syncDisplays(
                    Bool.random(using: &rng) ? displays : [displays[0]], main: displays[0]
                )
            case 12: manager.moveColumn(toDisplay: displays.randomElement(using: &rng)!)
            case 13: manager.moveWindow(toDisplay: displays.randomElement(using: &rng)!)
            case 14: manager.moveWorkspace(toDisplay: displays.randomElement(using: &rng)!)
            default:
                let target = manager.displayIDs.randomElement(using: &rng)!
                manager.focus(manager.activeID(on: target)!)
            }
            assertInvariants(manager)
            XCTAssertEqual(windows(manager), live, "window set drifted at step \(step)")
        }
    }

    /// Regression: without `[[workspace]]` the manager behaves exactly as
    /// before, whatever reloads happen (same seed, same operations).
    func testNoNamedWorkspacesChangesNothing() {
        var rng = SeededGenerator(state: 0xC0FFEE)
        var plain = WorkspaceManager()
        var reloaded = WorkspaceManager()
        var nextWindow: UInt64 = 1
        let displays = [DisplayID(21), DisplayID(22)]
        plain.syncDisplays(displays)
        reloaded.syncDisplays(displays)
        reloaded.applyNamedWorkspaces([])
        for step in 0..<2000 {
            let op = Int.random(in: 0..<9, using: &rng)
            let index = Int.random(in: 0...10, using: &rng)
            let pick = Bool.random(using: &rng)
            for manager in [0, 1] {
                var subject = manager == 0 ? plain : reloaded
                switch op {
                case 0, 1: put(&subject, nextWindow)
                case 2: subject.focusDown()
                case 3: subject.focusUp()
                case 4:
                    if let focused = subject.currentWorkspace().focusedWindow { subject.moveWindowDown(focused) }
                case 5:
                    if let focused = subject.currentWorkspace().focusedWindow { subject.moveWindowUp(focused) }
                case 6: subject.switchTo(index)
                case 7:
                    if let focused = subject.currentWorkspace().focusedWindow { subject.moveWindow(focused, to: index) }
                default:
                    subject.focus(subject.activeID(on: displays[pick ? 0 : 1])!)
                }
                if manager == 1, step % 7 == 0 {
                    subject.applyNamedWorkspaces([])
                }
                if manager == 0 { plain = subject } else { reloaded = subject }
            }
            if op <= 1 { nextWindow += 1 }
            XCTAssertEqual(plain, reloaded, "diverged at step \(step)")
        }
    }
}
