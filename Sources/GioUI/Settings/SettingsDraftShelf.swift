import Combine
import Foundation

/// DD-03 follow-up: unsaved settings edits survive switching sidebar
/// sections and closing the window. Each section parks its dirty draft here
/// and picks it up when it is shown again; clean drafts are not kept. The
/// sidebar marks sections that hold one.
public struct SettingsDraftShelf {
    private var drafts: [MainSection: Any] = [:]
    public private(set) var dirtySections: Set<MainSection> = []

    public init() {}

    public func hasUnsavedEdits(_ section: MainSection) -> Bool {
        dirtySections.contains(section)
    }

    /// Keep a dirty draft; a clean one clears the section.
    public mutating func store<Value: Equatable>(_ draft: SettingsDraft<Value>, for section: MainSection) {
        guard draft.isDirty else {
            discard(section)
            return
        }
        drafts[section] = draft
        dirtySections.insert(section)
    }

    public mutating func discard(_ section: MainSection) {
        drafts[section] = nil
        dirtySections.remove(section)
    }

    /// The kept draft brought up to date with what the session runs now
    /// (its edits stay), or a fresh draft of `saved`.
    public func restore<Value: Equatable>(for section: MainSection, saved: Value) -> SettingsDraft<Value> {
        guard var draft = drafts[section] as? SettingsDraft<Value> else {
            return SettingsDraft(saved: saved)
        }
        draft.adopt(saved: saved)
        return draft
    }
}

/// Main-window owner of the shelf; the sidebar observes it.
@MainActor
public final class SettingsDraftStore: ObservableObject {
    private var shelf = SettingsDraftShelf()
    /// Published on its own so a slider drag does not redraw the window;
    /// only a section turning dirty or clean does.
    @Published public private(set) var dirtySections: Set<MainSection> = []

    public init() {}

    func store<Value: Equatable>(_ draft: SettingsDraft<Value>, for section: MainSection) {
        shelf.store(draft, for: section)
        if dirtySections != shelf.dirtySections {
            dirtySections = shelf.dirtySections
        }
    }

    func restore<Value: Equatable>(for section: MainSection, saved: Value) -> SettingsDraft<Value> {
        shelf.restore(for: section, saved: saved)
    }
}
