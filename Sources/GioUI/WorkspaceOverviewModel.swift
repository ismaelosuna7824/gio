import CoreGraphics
import Foundation
import GioCore

/// WO-01: a captured window image for the overview, handed from the
/// session's capture task to the main thread.
public struct OverviewThumbnail: @unchecked Sendable {
    public let image: CGImage

    public init(image: CGImage) {
        self.image = image
    }
}

/// Thumbnails are drawn at roughly a third of the display, so a capture
/// never needs more than this many pixels per point.
public let overviewThumbnailScale: CGFloat = 0.75

/// Why the overview closed (logged).
public enum OverviewDismissReason: String, Sendable {
    case escape, toggle, resignKey, pick, background
}

/// Keys the panel hands to the model.
public enum OverviewKey: Equatable, Sendable {
    case step(OverviewStep)
    case enter
    case escape
    case digit(Int)
}

/// One workspace row: its label and the strip drawn to scale.
public struct WorkspaceOverviewRow: Equatable, Identifiable, Sendable {
    public let index: Int
    public let title: String
    public let icon: String?
    public let color: String?
    public let isActive: Bool
    public let miniature: WorkspaceMiniature

    public var id: Int { index }
}

/// Rows in stack order, named from the display's stack summary ("1 · Code").
public func workspaceOverviewRows(_ facts: WorkspaceOverviewFacts, stack: [WorkspaceEntry]) -> [WorkspaceOverviewRow] {
    facts.strips.map { strip in
        let entry = stack.first { $0.index == strip.workspace }
        return WorkspaceOverviewRow(
            index: strip.workspace,
            title: entry.map(workspaceTitle) ?? "Workspace \(strip.workspace)",
            icon: entry?.icon, color: entry?.color,
            isActive: strip.workspace == facts.activeWorkspace,
            miniature: workspaceMiniature(strip)
        )
    }
}

/// Row height that fits every workspace in `available` points (with
/// `spacing` between rows), clamped to `minimum...maximum`. Below the
/// minimum the rows scroll instead of shrinking further.
public func overviewRowHeight(
    rows: Int, available: CGFloat, spacing: CGFloat, minimum: CGFloat, maximum: CGFloat
) -> CGFloat {
    guard rows > 0 else {
        return maximum
    }
    let fitting = (available - spacing * CGFloat(rows - 1)) / CGFloat(rows)
    return min(max(fitting, minimum), maximum)
}

/// The overview's state for one presentation: rows, selection, the
/// thumbnails as they land. Picking closes the panel first, then asks the
/// session (a window that vanished meanwhile falls back to its workspace).
@MainActor
public final class WorkspaceOverviewModel: ObservableObject {
    public let facts: WorkspaceOverviewFacts
    public let rows: [WorkspaceOverviewRow]
    @Published public private(set) var selection: OverviewSelection
    @Published public private(set) var thumbnails: [String: OverviewThumbnail] = [:]
    var dismiss: ((OverviewDismissReason) -> Void)?
    private let titles: [String: String]
    private let focusWindow: (String) -> Bool
    private let focusWorkspace: (Int) -> Void

    public init(
        facts: WorkspaceOverviewFacts, stack: [WorkspaceEntry], titles: [String: String],
        focusWindow: @escaping (String) -> Bool, focusWorkspace: @escaping (Int) -> Void
    ) {
        self.facts = facts
        rows = workspaceOverviewRows(facts, stack: stack)
        selection = facts.initialSelection
        self.titles = titles
        self.focusWindow = focusWindow
        self.focusWorkspace = focusWorkspace
    }

    /// Every window the rows draw, in row then reading order.
    public var windowIDs: [String] {
        facts.strips.flatMap(overviewWindowOrder)
    }

    /// The window's title for its tile (UI only; never logged).
    public func title(of id: String) -> String? {
        titles[id].flatMap { $0.isEmpty ? nil : $0 }
    }

    public func setThumbnails(_ thumbnails: [String: OverviewThumbnail]) {
        self.thumbnails = thumbnails
    }

    /// The pointer moved over a tile or row.
    public func hover(_ selection: OverviewSelection) {
        if self.selection != selection {
            self.selection = selection
        }
    }

    /// True when the key was the overview's.
    @discardableResult
    public func handle(_ key: OverviewKey) -> Bool {
        switch key {
        case .step(let step):
            selection = facts.selection(selection, stepping: step)
        case .enter:
            pick(selection)
        case .escape:
            dismiss?(.escape)
        case .digit(let index):
            guard facts.strip(index) != nil else {
                return false
            }
            pick(OverviewSelection(workspace: index, windowID: nil))
        }
        return true
    }

    public func pick(_ selection: OverviewSelection) {
        dismiss?(.pick)
        if let id = selection.windowID, focusWindow(id) {
            return
        }
        focusWorkspace(selection.workspace)
    }
}
