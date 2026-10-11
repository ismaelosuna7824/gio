import GioCore
import XCTest
@testable import GioUI

/// DW-03: the per-workspace layout picker on the Workspaces cards.
final class DwindleWorkspaceCardTests: XCTestCase {
    func testACardCarriesItsLayoutIntoTheWorkspaceBlock() {
        var config = GioConfig()
        config.workspaces = [WorkspaceDefinition(name: "Code", layout: .dwindle), WorkspaceDefinition(name: "Web")]
        var draft = WorkspacesDraft(config: config)
        XCTAssertEqual(draft.cards.map(\.layout), [.dwindle, nil])
        XCTAssertEqual(draft.cards[0].definition.layout, .dwindle)
        XCTAssertEqual(workspaceConfigEdits(config: config, draft: draft), [], "unchanged: no edit")

        draft.cards[1].layout = .dwindle
        XCTAssertEqual(
            workspaceConfigEdits(config: config, draft: draft),
            [.updateWorkspace(index: 1, WorkspaceDefinition(name: "Web", layout: .dwindle))]
        )
        XCTAssertEqual(workspaceLayoutOptions.map(\.1), ["Default", "Scrolling", "Dwindle"])
        XCTAssertEqual(workspaceLayoutLabel(nil, default: .dwindle), "Default (Dwindle)")
        XCTAssertEqual(workspaceLayoutLabel(.scrolling, default: .dwindle), "Scrolling")
    }
}
