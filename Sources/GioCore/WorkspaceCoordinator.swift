import Foundation
import CoreGraphics

public protocol WorkspaceWindowBridge {
    associatedtype Handle
    func checkPermission() throws
    func capture(_ window: WindowID) throws -> (handle: Handle, frame: CGRect)
    func frame(of handle: Handle) throws -> CGRect
    func move(_ handle: Handle, to origin: CGPoint) throws
    func canTile(_ handle: Handle) throws -> Bool
    func apply(_ handle: Handle, frame: CGRect) throws
}

public enum WorkspaceCoordinatorError: Error {
    case unsafeParking(DisplayID)
    case invalidDisplayRect(DisplayID)
    case recoveryRequired
    case noSafeRestorePosition(WindowID)
    case operationFailed(Error, rollbackFailures: [Error])
}

/// CG display bounds and AX window positions use global top-left coordinates on macOS.
public final class WorkspaceCoordinator<Bridge: WorkspaceWindowBridge> {
    private struct Controlled {
        var handle: Bridge.Handle
        var initial: CGRect
        var parked: Bool = false
        var preTile: CGRect?
        var restoredWhileParked: CGRect?
    }

    public private(set) var model = WorkspaceModel()
    public private(set) var recoveryRequired = false

    private func requireReady() throws {
        if recoveryRequired { throw WorkspaceCoordinatorError.recoveryRequired }
    }
    private let bridge: Bridge
    private var displays: [DisplayID: CGRect] = [:]
    private var controlled: [WindowID: Controlled] = [:]

    public init(bridge: Bridge) { self.bridge = bridge }

    public func addDisplay(_ id: DisplayID, rect: CGRect, initialWorkspace: WorkspaceID) throws {
        try requireReady()
        guard rect.isFinitePositive else { throw WorkspaceCoordinatorError.invalidDisplayRect(id) }
        var next = model
        try next.addDisplay(id, initialWorkspace: initialWorkspace)
        displays[id] = rect
        model = next
    }

    public func addWorkspace(_ id: WorkspaceID, on display: DisplayID) throws {
        try requireReady()
        var next = model
        try next.addWorkspace(id, on: display)
        model = next
    }

    public func assign(_ window: WindowID, to workspace: WorkspaceID, on display: DisplayID) throws {
        try requireReady()
        try bridge.checkPermission()
        var next = model
        let changes = try next.assign(window, to: workspace, on: display)
        let snapshot = try bridge.capture(window)
        var entries = controlled
        entries[window] = Controlled(handle: snapshot.handle, initial: snapshot.frame)
        try execute(changes, model: next, entries: &entries)
        controlled = entries
        model = next
    }

    public func switchTo(_ workspace: WorkspaceID, on display: DisplayID) throws {
        try requireReady()
        try bridge.checkPermission()
        var next = model
        let changes = try next.switchTo(workspace, on: display)
        var entries = controlled
        try execute(changes, model: next, entries: &entries)
        controlled = entries
        model = next
    }

    public func reassign(_ window: WindowID, to workspace: WorkspaceID, on display: DisplayID) throws {
        try requireReady()
        try bridge.checkPermission()
        let old = try model.membership(of: window)
        var next = model
        let changes = try next.reassign(window, to: workspace, on: display)
        var entries = controlled
        // Transfers with unchanged visibility still require relocation on the target display.
        if changes.isEmpty && old.display != display {
            let entry = entries[window]!
            let target = try entry.parked
                ? parking(on: display, size: bridge.frame(of: entry.handle).size)
                : destination(window, on: display, entry: entry)
            try executeMoves([(window, target)], entries: &entries)
        } else {
            try execute(changes, model: next, entries: &entries)
        }
        controlled = entries
        model = next
    }

    @discardableResult
    public func reflow(on display: DisplayID, usableBounds: CGRect,
                       outerGap: CGFloat = 0, innerGap: CGFloat = 0) throws -> [WindowID] {
        try requireReady()
        guard let bounds = displays[display] else { throw WorkspaceModelError.unknownDisplay(display) }
        guard usableBounds.isFinitePositive, bounds.contains(usableBounds) else {
            throw WorkspaceCoordinatorError.invalidDisplayRect(display)
        }
        try bridge.checkPermission()
        let active = try model.activeWorkspace(on: display)
        let ids = try controlled.keys.sorted { $0.rawValue < $1.rawValue }.filter {
            let membership = try model.membership(of: $0)
            return membership.display == display && membership.workspace == active
        }
        var eligible: [WindowID] = []
        var skipped: [WindowID] = []
        for id in ids {
            if try bridge.canTile(controlled[id]!.handle) { eligible.append(id) }
            else { skipped.append(id) }
        }
        let targets = try TileLayout.plan(windows: eligible, in: usableBounds,
                                          outerGap: outerGap, innerGap: innerGap)
        var entries = controlled
        try executeFrames(targets.map { ($0.window, $0.frame) }, entries: &entries, capturePreTile: true)
        controlled = entries
        return skipped
    }

    public func restoreTiledFrames(on display: DisplayID) throws {
        try requireReady()
        guard displays[display] != nil else { throw WorkspaceModelError.unknownDisplay(display) }
        try bridge.checkPermission()
        var entries = controlled
        let ids = try entries.keys.sorted { $0.rawValue < $1.rawValue }.filter {
            try model.membership(of: $0).display == display && entries[$0]!.preTile != nil
        }
        let targets: [(WindowID, CGRect)] = try ids.map { id in
            let entry = entries[id]!
            let frame = entry.preTile!
            if entry.parked {
                let origin = try parking(on: display, size: frame.size)
                return (id, CGRect(origin: origin, size: frame.size))
            }
            return (id, frame)
        }
        try executeFrames(targets, entries: &entries)
        for id in ids {
            if entries[id]!.parked { entries[id]!.restoredWhileParked = entries[id]!.preTile }
            entries[id]!.preTile = nil
        }
        controlled = entries
    }

    public func removeWindow(_ window: WindowID) throws {
        try requireReady()
        try bridge.checkPermission()
        var next = model
        _ = try next.removeWindow(window)
        var entries = controlled
        try executeFrames([(window, entries[window]!.initial)], entries: &entries)
        entries.removeValue(forKey: window)
        controlled = entries
        model = next
    }

    /// Only call after independent evidence that the window no longer exists (for example,
    /// its owning process terminated). No AX access or restoration is possible then.
    public func forgetClosedWindow(_ window: WindowID) throws {
        var next = model
        _ = try next.removeWindow(window)
        controlled.removeValue(forKey: window)
        model = next
    }

    public func removeDisplay(_ display: DisplayID) throws {
        try requireReady()
        try bridge.checkPermission()
        var next = model
        try next.removeDisplay(display)
        var entries = controlled
        let owned = try controlled.keys.sorted { $0.rawValue < $1.rawValue }.filter {
            try model.membership(of: $0).display == display
        }
        try executeFrames(owned.map { ($0, entries[$0]!.initial) }, entries: &entries)
        for id in owned { entries.removeValue(forKey: id) }
        controlled = entries
        displays.removeValue(forKey: display)
        model = next
    }

    /// Connected bounds override stale coordinates when restoring owned windows.
    public func shutdown(connectedDisplays: [DisplayID: CGRect]) throws {
        guard !connectedDisplays.isEmpty || controlled.isEmpty,
              connectedDisplays.values.allSatisfy(\.isFinitePositive) else {
            throw WorkspaceCoordinatorError.recoveryRequired
        }
        try restoreAll(connectedDisplays: connectedDisplays)
    }

    public func shutdown() throws { try restoreAll(connectedDisplays: displays) }

    private func restoreAll(connectedDisplays: [DisplayID: CGRect]) throws {
        // With no owned windows, shutdown has nothing to restore through AX.
        // Keep the permission gate when any ownership remains, including recovery mode.
        if !controlled.isEmpty { try bridge.checkPermission() }
        var entries = controlled
        let ids = entries.keys.sorted { $0.rawValue < $1.rawValue }
        // Reserve every retained original placement before allocating any fallback, regardless of ID order.
        var occupied: [CGRect] = []
        var displaced: [WindowID] = []
        var moves: [(WindowID, CGPoint)] = []
        for id in ids {
            let owner = try model.membership(of: id).display
            let initial = entries[id]!.initial
            _ = try bridge.frame(of: entries[id]!.handle)
            if (connectedDisplays[owner]?.contains(initial) ?? false) ||
                connectedDisplays.values.contains(where: { $0.contains(initial) }) {
                moves.append((id, initial.origin))
                occupied.append(initial)
            } else {
                displaced.append(id)
            }
        }
        for id in displaced {
            let size = entries[id]!.initial.size
            var placement: CGRect?
            for display in connectedDisplays.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let bounds = connectedDisplays[display] else { continue }
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
            guard let placement else { throw WorkspaceCoordinatorError.noSafeRestorePosition(id) }
            occupied.append(placement)
            moves.append((id, placement.origin))
        }
        try executeFrames(moves.map { (id, origin) in
            (id, CGRect(origin: origin, size: entries[id]!.initial.size))
        }, entries: &entries)
        controlled.removeAll()
        displays.removeAll()
        model = WorkspaceModel()
        recoveryRequired = false
    }

    private func execute(_ changes: [WindowTransition], model next: WorkspaceModel,
                         entries: inout [WindowID: Controlled]) throws {
        // Parking and workspace visibility remain position-only, never resize a window.
        let moves: [(WindowID, CGPoint)] = try changes.map { change in
            switch change {
            case .hide(let id):
                let display = try next.membership(of: id).display
                return (id, try parking(on: display, size: bridge.frame(of: entries[id]!.handle).size))
            case .show(let id):
                let display = try next.membership(of: id).display
                return (id, try destination(id, on: display, entry: entries[id]!))
            }
        }
        let restoring = changes.contains { change in
            if case .show(let id) = change { return entries[id]!.restoredWhileParked != nil }
            return false
        }
        if restoring {
            // Mixed hides and full-frame shows share one rollback boundary.
            var previous: [(WindowID, CGRect)] = []
            do {
                for change in changes {
                    let id: WindowID
                    switch change {
                    case .hide(let window), .show(let window): id = window
                    }
                    let before = try bridge.frame(of: entries[id]!.handle)
                    previous.append((id, before))
                    if case .show = change, let frame = entries[id]!.restoredWhileParked {
                        guard let bounds = displays[try next.membership(of: id).display], bounds.contains(frame) else {
                            throw WorkspaceCoordinatorError.noSafeRestorePosition(id)
                        }
                        try bridge.apply(entries[id]!.handle, frame: frame)
                    } else {
                        try bridge.move(entries[id]!.handle, to: moves[previous.count - 1].1)
                    }
                }
            } catch {
                var failures: [Error] = []
                for (id, frame) in previous.reversed() {
                    do { try bridge.apply(entries[id]!.handle, frame: frame) }
                    catch { failures.append(error) }
                }
                if !failures.isEmpty { recoveryRequired = true }
                throw WorkspaceCoordinatorError.operationFailed(error, rollbackFailures: failures)
            }
        } else {
            try executeMoves(moves, entries: &entries)
        }
        for change in changes {
            switch change {
            case .hide(let id): entries[id]!.parked = true
            case .show(let id):
                entries[id]!.parked = false
                entries[id]!.restoredWhileParked = nil
            }
        }
    }

    private func executeMoves(_ moves: [(WindowID, CGPoint)], entries: inout [WindowID: Controlled]) throws {
        var originals: [(WindowID, CGPoint)] = []
        do {
            for (id, position) in moves {
                let handle = entries[id]!.handle
                let before = try bridge.frame(of: handle).origin
                originals.append((id, before)) // Include the failing move: AX may mutate then report failure.
                try bridge.move(handle, to: position)
            }
        } catch {
            var failures: [Error] = []
            for (id, origin) in originals.reversed() {
                do { try bridge.move(entries[id]!.handle, to: origin) }
                catch { failures.append(error) }
            }
            if !failures.isEmpty { recoveryRequired = true }
            throw WorkspaceCoordinatorError.operationFailed(error, rollbackFailures: failures)
        }
    }

    private func executeFrames(_ targets: [(WindowID, CGRect)], entries: inout [WindowID: Controlled],
                               capturePreTile: Bool = false) throws {
        var originals: [(WindowID, CGRect)] = []
        do {
            for (id, target) in targets {
                let handle = entries[id]!.handle
                let before = try bridge.frame(of: handle)
                originals.append((id, before)) // A failing AX write may already have mutated the window.
                try bridge.apply(handle, frame: target)
            }
        } catch {
            var failures: [Error] = []
            for (id, frame) in originals.reversed() {
                do { try bridge.apply(entries[id]!.handle, frame: frame) }
                catch { failures.append(error) }
            }
            if !failures.isEmpty { recoveryRequired = true }
            throw WorkspaceCoordinatorError.operationFailed(error, rollbackFailures: failures)
        }
        if capturePreTile {
            for (id, before) in originals where entries[id]!.preTile == nil {
                entries[id]!.preTile = before
            }
        }
    }

    private func destination(_ id: WindowID, on display: DisplayID, entry: Controlled) throws -> CGPoint {
        guard let rect = displays[display] else { throw WorkspaceModelError.unknownDisplay(display) }
        let target = entry.restoredWhileParked ?? entry.initial
        if rect.contains(target) { return target.origin }
        return CGPoint(x: rect.minX + 1, y: rect.minY + 1)
    }

    private func parking(on display: DisplayID, size: CGSize) throws -> CGPoint {
        guard let rect = displays[display] else { throw WorkspaceModelError.unknownDisplay(display) }
        // Leave at most a one-pixel strip inside the owning display.
        let candidates = [CGPoint(x: rect.minX - size.width + 1, y: rect.maxY - 1),
                          CGPoint(x: rect.maxX - 1, y: rect.maxY - 1)]
        for point in candidates {
            let parked = CGRect(origin: point, size: size)
            if displays.allSatisfy({ $0.key == display || !$0.value.intersects(parked) }) {
                return point
            }
        }
        throw WorkspaceCoordinatorError.unsafeParking(display)
    }
}

private extension CGRect {
    var isFinitePositive: Bool {
        [minX, minY, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}
