import Foundation
import GioCore

/// Read-only view of the live session, built by the host on the session
/// queue and handed to the main thread by value. Views never touch session
/// state directly.
public struct SessionSnapshot: Sendable {
    /// Config-file keybindings (layered over the defaults by the catalog).
    public var keybindings: [(HotkeyCombo, HotkeyAction)]
    /// Session, permission and window facts; nil before the first fetch.
    public var facts: SessionFacts?
    /// The config the session is running with right now.
    public var config: GioConfig

    public init(
        keybindings: [(HotkeyCombo, HotkeyAction)] = [], facts: SessionFacts? = nil,
        config: GioConfig = GioConfig()
    ) {
        self.keybindings = keybindings
        self.facts = facts
        self.config = config
    }
}

/// What the window can ask the session to do. Every closure hops onto the
/// session queue inside the host; the UI never mutates session state.
public struct DesktopActions: Sendable {
    /// Patch config.toml, then reload it in the running session.
    public var applyEdits: @Sendable ([ConfigEdit]) -> Result<PatchedConfig, ConfigErrors>

    public init(
        applyEdits: @escaping @Sendable ([ConfigEdit]) -> Result<PatchedConfig, ConfigErrors>
    ) {
        self.applyEdits = applyEdits
    }

    /// Actions that only report "unavailable" (previews and tests).
    public static let unavailable = DesktopActions(
        applyEdits: { _ in .failure(ConfigErrors(messages: ["not connected to a session"])) }
    )
}

/// Outcome of one Apply, ready for inline display.
public enum ApplyFeedback: Equatable, Sendable {
    case applied(warnings: [String])
    case rejected(messages: [String])
}

/// Main-thread model behind the window. `fetch` is host-provided and may
/// block briefly on the session queue.
@MainActor
public final class DesktopModel: ObservableObject {
    @Published public private(set) var snapshot = SessionSnapshot()
    private let fetch: @Sendable () -> SessionSnapshot
    private let actions: DesktopActions

    public init(
        fetch: @escaping @Sendable () -> SessionSnapshot,
        actions: DesktopActions = .unavailable
    ) {
        self.fetch = fetch
        self.actions = actions
        refresh()
    }

    public func refresh() {
        snapshot = fetch()
    }

    /// Patch the config file and reload it live; the snapshot then reflects
    /// the reloaded config. Invalid edits are rejected with the parser's
    /// messages and leave the file untouched.
    @discardableResult
    public func apply(_ edits: [ConfigEdit]) -> ApplyFeedback {
        let feedback: ApplyFeedback
        switch actions.applyEdits(edits) {
        case .success(let patched): feedback = .applied(warnings: patched.warnings)
        case .failure(let errors): feedback = .rejected(messages: errors.messages)
        }
        refresh()
        return feedback
    }
}
