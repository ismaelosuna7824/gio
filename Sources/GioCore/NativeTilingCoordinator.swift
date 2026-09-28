import Foundation
import CoreGraphics

public enum NativeTilingError: Error {
    case invalidDisplayRect(DisplayID)
    case unknownDisplay(DisplayID)
    case unknownWindow(WindowID)
    case noSafeRestorePosition(WindowID)
    case recoveryRequired
    case operationFailed(Error, rollbackFailures: [Error])
}

/// Owns only windows explicitly adopted by the caller; Space snapshots never revoke ownership.
public final class NativeTilingCoordinator<Bridge: WindowFrameBridge> {
    private struct Owned {
        let handle: Bridge.Handle
        let original: CGRect
        var display: DisplayID
        var preTile: CGRect?
    }

    private let bridge: Bridge
    private var displays: [DisplayID: CGRect] = [:]
    private var owned: [WindowID: Owned] = [:]
    public private(set) var recoveryRequired = false

    public init(bridge: Bridge) { self.bridge = bridge }

    private func ready() throws {
        if recoveryRequired { throw NativeTilingError.recoveryRequired }
    }

    public func registerDisplay(_ id: DisplayID, bounds: CGRect) throws {
        try ready()
        guard bounds.isFinitePositive else { throw NativeTilingError.invalidDisplayRect(id) }
        displays[id] = bounds
    }

    /// Call only for positively selected current-Space windows, never for an inferred match.
    public func adopt(_ id: WindowID, on display: DisplayID) throws {
        try ready()
        guard displays[display] != nil else { throw NativeTilingError.unknownDisplay(display) }
        if owned[id] != nil {
            // A fresh positive selection can update display ownership without replacing
            // the captured original, handle, or outstanding pre-tile restoration.
            owned[id]!.display = display
            return
        }
        try bridge.checkPermission()
        let captured = try bridge.capture(id)
        owned[id] = Owned(handle: captured.handle, original: captured.frame, display: display)
    }

    /// Selected IDs are the caller's positively identified active-Space cohort.
    @discardableResult
    public func reflow(on display: DisplayID, selected: Set<WindowID>, usableBounds: CGRect,
                       outerGap: CGFloat = 0, innerGap: CGFloat = 0) throws -> [WindowID] {
        try ready()
        guard let bounds = displays[display] else { throw NativeTilingError.unknownDisplay(display) }
        guard usableBounds.isFinitePositive, bounds.contains(usableBounds) else {
            throw NativeTilingError.invalidDisplayRect(display)
        }
        let ids = selected.sorted { $0.rawValue < $1.rawValue }
        for id in ids {
            guard let entry = owned[id], entry.display == display else { throw NativeTilingError.unknownWindow(id) }
        }
        try bridge.checkPermission()
        var eligible: [WindowID] = []
        var skipped: [WindowID] = []
        for id in ids {
            if try bridge.canTile(owned[id]!.handle) { eligible.append(id) }
            else { skipped.append(id) }
        }
        let targets = try TileLayout.plan(windows: eligible, in: usableBounds,
                                          outerGap: outerGap, innerGap: innerGap)
        let before = try apply(targets.map { ($0.window, $0.frame) })
        for (id, frame) in before where owned[id]!.preTile == nil { owned[id]!.preTile = frame }
        return skipped
    }

    /// Disabling one display restores its owned tiled windows, including inactive-Space cohorts.
    public func restoreTiledFrames(on display: DisplayID) throws {
        try ready()
        guard displays[display] != nil else { throw NativeTilingError.unknownDisplay(display) }
        let ids = owned.keys.sorted { $0.rawValue < $1.rawValue }.filter { owned[$0]!.display == display }
        let tiled = ids.filter { owned[$0]!.preTile != nil }
        if !tiled.isEmpty { try bridge.checkPermission() }
        _ = try apply(tiled.map { ($0, owned[$0]!.preTile!) })
        // Commit release only after every restore succeeds. A later enable must capture
        // the user's current frame rather than an original from the previous cycle.
        for id in ids { owned.removeValue(forKey: id) }
    }

    /// Requires trusted closure evidence from the caller. Snapshot absence is not closure evidence.
    public func forgetClosedWindow(_ id: WindowID) {
        owned.removeValue(forKey: id)
    }

    /// Caller must supply a fresh connected-display snapshot; registered bounds can be stale
    /// after a disconnect and must never authorize restoration or release ownership.
    public func shutdown(connectedDisplays: [DisplayID: CGRect]) throws {
        guard connectedDisplays.values.allSatisfy(\.isFinitePositive) else {
            throw NativeTilingError.recoveryRequired
        }
        // Only windows Gio actually tiled need restoration; untouched adopted windows
        // may have been moved manually and must not be written or reserve fallback space.
        let ids = owned.keys.sorted { $0.rawValue < $1.rawValue }.filter { owned[$0]!.preTile != nil }
        if !ids.isEmpty { try bridge.checkPermission() }
        var occupied: [CGRect] = []
        var displaced: [WindowID] = []
        var targets: [(WindowID, CGRect)] = []
        for id in ids {
            let original = owned[id]!.original
            if connectedDisplays.values.contains(where: { $0.contains(original) }) {
                targets.append((id, original))
                occupied.append(original)
            } else { displaced.append(id) }
        }
        for id in displaced {
            let size = owned[id]!.original.size
            var placement: CGRect?
            for display in connectedDisplays.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let bounds = connectedDisplays[display]!
                let xs = [bounds.minX] + occupied.map(\.maxX).filter { $0 >= bounds.minX && $0 < bounds.maxX }
                let ys = [bounds.minY] + occupied.map(\.maxY).filter { $0 >= bounds.minY && $0 < bounds.maxY }
                for y in ys.sorted() where placement == nil {
                    for x in xs.sorted() {
                        let candidate = CGRect(origin: CGPoint(x: x, y: y), size: size)
                        if bounds.contains(candidate) && !occupied.contains(where: { $0.intersects(candidate) }) {
                            placement = candidate
                            break
                        }
                    }
                }
                if placement != nil { break }
            }
            guard let placement else { throw NativeTilingError.noSafeRestorePosition(id) }
            targets.append((id, placement))
            occupied.append(placement)
        }
        _ = try apply(targets)
        owned.removeAll()
        displays.removeAll()
        recoveryRequired = false
    }

    private func apply(_ targets: [(WindowID, CGRect)]) throws -> [(WindowID, CGRect)] {
        var previous: [(WindowID, CGRect)] = []
        do {
            for (id, target) in targets {
                let handle = owned[id]!.handle
                let before = try bridge.frame(of: handle)
                previous.append((id, before)) // A failed AX write may already have mutated its target.
                try bridge.apply(handle, frame: target)
            }
        } catch {
            var failures: [Error] = []
            for (id, frame) in previous.reversed() {
                do { try bridge.apply(owned[id]!.handle, frame: frame) }
                catch { failures.append(error) }
            }
            if !failures.isEmpty {
                recoveryRequired = true
                // Failed rollback may leave a window modified even on its first tile.
                // Retain the pre-write frame for a later explicit recovery shutdown.
                for (id, frame) in previous where owned[id]!.preTile == nil {
                    owned[id]!.preTile = frame
                }
            }
            throw NativeTilingError.operationFailed(error, rollbackFailures: failures)
        }
        return previous
    }
}

private extension CGRect {
    var isFinitePositive: Bool {
        [minX, minY, maxX, maxY, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}
