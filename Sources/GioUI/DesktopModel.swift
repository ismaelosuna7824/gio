import Foundation
import GioCore

/// Read-only view of the live session, built by the host on the session
/// queue and handed to the main thread by value. Views never touch session
/// state directly.
public struct SessionSnapshot: Sendable {
    /// Config-file keybindings (layered over the defaults by the catalog).
    public var keybindings: [(HotkeyCombo, HotkeyAction)]

    public init(keybindings: [(HotkeyCombo, HotkeyAction)] = []) {
        self.keybindings = keybindings
    }
}

/// Main-thread model behind the window. `fetch` is host-provided and may
/// block briefly on the session queue.
@MainActor
public final class DesktopModel: ObservableObject {
    @Published public private(set) var snapshot = SessionSnapshot()
    private let fetch: @Sendable () -> SessionSnapshot

    public init(fetch: @escaping @Sendable () -> SessionSnapshot) {
        self.fetch = fetch
        refresh()
    }

    public func refresh() {
        snapshot = fetch()
    }
}
