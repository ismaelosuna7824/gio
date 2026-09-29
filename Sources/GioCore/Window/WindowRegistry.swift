import CoreGraphics
import Foundation

public enum WindowRegistryError: Error, Equatable, Sendable {
    case duplicate(WindowID)
    case unknown(WindowID)
}

/// Plan §7 registry: the single owner of window membership. It registers,
/// removes, finds and updates windows, and distinguishes managed from
/// ignored windows. Ignored windows are remembered by ID so decks, panels
/// and other never-tile windows stay out without repeated decisions.
///
/// Event sync convention: after each enumeration the adapter calls
/// `removeStale(keeping:)` with the live ID set. Absence from one
/// enumeration only removes the record here; ownership lifetime across
/// Space changes is decided by upper layers, never by this type.
public final class WindowRegistry {
    private var windows: [WindowID: ManagedWindow] = [:]
    private var ignored: Set<WindowID> = []

    public init() {}

    /// Insert a new window. Throws `duplicate` when the ID exists — use
    /// `update` for metadata changes on known windows.
    public func register(_ window: ManagedWindow) throws {
        guard windows[window.id] == nil else {
            throw WindowRegistryError.duplicate(window.id)
        }
        windows[window.id] = window
    }

    /// Replace the record for a known window. Throws `unknown` for new IDs.
    public func update(_ window: ManagedWindow) throws {
        guard windows[window.id] != nil else {
            throw WindowRegistryError.unknown(window.id)
        }
        windows[window.id] = window
    }

    /// Remove a record, returning it. Also clears any ignore mark.
    @discardableResult
    public func remove(_ id: WindowID) -> ManagedWindow? {
        ignored.remove(id)
        return windows.removeValue(forKey: id)
    }

    public func find(_ id: WindowID) -> ManagedWindow? {
        windows[id]
    }

    /// Mark an ID as never-managed. Allowed for unknown IDs so a rule can
    /// precede the window's arrival.
    public func ignore(_ id: WindowID) {
        ignored.insert(id)
    }

    public func unignore(_ id: WindowID) {
        ignored.remove(id)
    }

    public func isIgnored(_ id: WindowID) -> Bool {
        ignored.contains(id)
    }

    /// Registered and not ignored.
    public func isManaged(_ id: WindowID) -> Bool {
        windows[id] != nil && !ignored.contains(id)
    }

    /// Managed windows in deterministic ID order.
    public func managedWindows() -> [ManagedWindow] {
        windows.keys.sorted().compactMap { id in
            guard !ignored.contains(id) else {
                return nil
            }
            return windows[id]
        }
    }

    /// Drop every record whose ID is not live. Returns the removed windows in
    /// deterministic ID order. Ignore marks for vanished IDs are kept: the
    /// ignore decision outlives any single enumeration.
    @discardableResult
    public func removeStale(keeping liveIDs: Set<WindowID>) -> [ManagedWindow] {
        let stale = windows.keys.filter { !liveIDs.contains($0) }.sorted()
        return stale.compactMap { windows.removeValue(forKey: $0) }
    }

    public var registeredCount: Int {
        windows.count
    }

    public var ignoredCount: Int {
        ignored.count
    }

    /// Remove every record owned by a terminated process, returning them in
    /// ID order. Termination notifications are proof of death (unlike mere
    /// absence from an enumeration), so this runs even when snapshots are
    /// incomplete — see Recovery. Ignore marks for unknown IDs survive: a
    /// rule may precede the window's arrival, and bare IDs match nothing.
    @discardableResult
    public func removeWindows(ofPID pid: pid_t) -> [ManagedWindow] {
        let ids = windows.values.filter { $0.pid == pid }.map(\.id).sorted()
        return ids.compactMap { remove($0) }
    }

    /// Plan §17 mode lifecycle. Set any mode; unknown IDs throw.
    public func setMode(_ mode: WindowMode, for id: WindowID) throws {
        guard var window = windows[id] else {
            throw WindowRegistryError.unknown(id)
        }
        window.mode = mode
        if mode != .floating {
            window.floatReason = nil
        }
        windows[id] = window
    }

    /// Mark a window minimized or not without touching its mode or place.
    /// Unknown IDs throw.
    public func setMinimized(_ minimized: Bool, for id: WindowID) throws {
        guard var window = windows[id] else {
            throw WindowRegistryError.unknown(id)
        }
        window.isMinimized = minimized
        windows[id] = window
    }

    /// Float a window and record why. Unknown IDs throw.
    public func setFloating(_ reason: FloatReason, for id: WindowID) throws {
        guard var window = windows[id] else {
            throw WindowRegistryError.unknown(id)
        }
        window.mode = .floating
        window.floatReason = reason
        windows[id] = window
    }

    /// Toggle tiled ↔ floating, returning the new mode. From fullscreen it
    /// exits to tiled (the grid), not to floating — leaving fullscreen and
    /// floating are separate actions. Unknown IDs throw.
    @discardableResult
    public func toggleFloating(for id: WindowID) throws -> WindowMode {
        guard var window = windows[id] else {
            throw WindowRegistryError.unknown(id)
        }
        switch window.mode {
        case .tiled:
            window.mode = .floating
            window.floatReason = .manual
        case .floating, .fullscreen:
            window.mode = .tiled
            window.floatReason = nil
        }
        windows[id] = window
        return window.mode
    }

    /// Enter fullscreen on the given display frame, capturing the record to
    /// restore on exit. Unknown IDs throw.
    @discardableResult
    public func beginFullscreen(id: WindowID, frame: CGRect) throws -> FullscreenRecord {
        guard var window = windows[id] else {
            throw WindowRegistryError.unknown(id)
        }
        let record = FullscreenRecord(
            id: id, previousFrame: window.frame, previousMode: window.mode
        )
        window.mode = .fullscreen
        window.frame = frame
        windows[id] = window
        return record
    }

    /// Restore a captured record (frame + mode). Last writer wins by design:
    /// concurrent mode changes between begin and end are overwritten.
    /// Unknown IDs throw.
    public func endFullscreen(_ record: FullscreenRecord) throws {
        guard var window = windows[record.id] else {
            throw WindowRegistryError.unknown(record.id)
        }
        window.mode = record.previousMode
        window.frame = record.previousFrame
        windows[record.id] = window
    }
}
