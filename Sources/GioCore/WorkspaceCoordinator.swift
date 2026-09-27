import Foundation
import CoreGraphics

public protocol WorkspaceWindowBridge {
    associatedtype Handle
    func checkPermission() throws
    func capture(_ window: WindowID) throws -> (handle: Handle, frame: CGRect)
    func frame(of handle: Handle) throws -> CGRect
    func move(_ handle: Handle, to origin: CGPoint) throws
}

public enum WorkspaceCoordinatorError: Error {
    case unsafeParking(DisplayID)
    case invalidDisplayRect(DisplayID)
    case recoveryRequired
    case operationFailed(Error, rollbackFailures: [Error])
}

/// CG display bounds and AX window positions use global top-left coordinates on macOS.
public final class WorkspaceCoordinator<Bridge: WorkspaceWindowBridge> {
    private struct Controlled {
        var handle: Bridge.Handle
        var initial: CGRect
        var parked: Bool = false
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
                ? parking(on: display, size: entry.initial.size)
                : destination(window, on: display, entry: entry)
            try executeMoves([(window, target)], entries: &entries)
        } else {
            try execute(changes, model: next, entries: &entries)
        }
        controlled = entries
        model = next
    }

    public func removeWindow(_ window: WindowID) throws {
        try requireReady()
        try bridge.checkPermission()
        var next = model
        _ = try next.removeWindow(window)
        var entries = controlled
        try executeMoves([(window, entries[window]!.initial.origin)], entries: &entries)
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
        try executeMoves(owned.map { ($0, entries[$0]!.initial.origin) }, entries: &entries)
        for id in owned { entries.removeValue(forKey: id) }
        controlled = entries
        displays.removeValue(forKey: display)
        model = next
    }

    public func shutdown() throws {
        // With no owned windows, shutdown has nothing to restore through AX.
        // Keep the permission gate when any ownership remains, including recovery mode.
        if !controlled.isEmpty { try bridge.checkPermission() }
        var entries = controlled
        let ids = entries.keys.sorted { $0.rawValue < $1.rawValue }
        try executeMoves(ids.map { ($0, entries[$0]!.initial.origin) }, entries: &entries)
        controlled.removeAll()
        displays.removeAll()
        model = WorkspaceModel()
        recoveryRequired = false
    }

    private func execute(_ changes: [WindowTransition], model next: WorkspaceModel,
                         entries: inout [WindowID: Controlled]) throws {
        let moves: [(WindowID, CGPoint)] = try changes.map { change in
            switch change {
            case .hide(let id):
                let display = try next.membership(of: id).display
                return (id, try parking(on: display, size: entries[id]!.initial.size))
            case .show(let id):
                let display = try next.membership(of: id).display
                return (id, try destination(id, on: display, entry: entries[id]!))
            }
        }
        try executeMoves(moves, entries: &entries)
        for change in changes {
            switch change {
            case .hide(let id): entries[id]!.parked = true
            case .show(let id): entries[id]!.parked = false
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

    private func destination(_ id: WindowID, on display: DisplayID, entry: Controlled) throws -> CGPoint {
        guard let rect = displays[display] else { throw WorkspaceModelError.unknownDisplay(display) }
        if rect.contains(entry.initial) { return entry.initial.origin }
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
