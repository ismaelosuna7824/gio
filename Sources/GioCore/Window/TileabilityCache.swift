import Foundation

public enum TileabilityProbe: Equatable, Sendable {
    case tileable
    case notTileable
    case undetermined(status: Int)
}

public enum TileabilityResolution: Equatable, Sendable {
    case tileable
    case notTileable
    case undetermined(status: Int)
    case retryPending
}

/// Per-window memo of the "can this window be resized?" probe. The probe
/// costs several Accessibility calls, so reflows reuse the verdict until the
/// window is (re)registered, an attribute/resize event or an explicit resync
/// invalidates it. An undetermined probe is not a verdict: the window is
/// probed again after `retryInterval`. Pure value type: the host owns one
/// and wires the events.
public struct TileabilityCache: Sendable {
    public static let retryInterval: TimeInterval = 5

    private var verdicts: [WindowID: Bool] = [:]
    private var retryDeadlines: [WindowID: TimeInterval] = [:]

    public init() {}

    public func verdict(for id: WindowID) -> Bool? {
        verdicts[id]
    }

    /// Cached verdict, or run `probe` once and remember a definite answer.
    public mutating func resolve(
        _ id: WindowID, now: TimeInterval, probe: () -> TileabilityProbe
    ) -> TileabilityResolution {
        if let cached = verdicts[id] {
            return cached ? .tileable : .notTileable
        }
        if let deadline = retryDeadlines[id], now < deadline {
            return .retryPending
        }
        switch probe() {
        case .tileable:
            remember(true, for: id)
            return .tileable
        case .notTileable:
            remember(false, for: id)
            return .notTileable
        case .undetermined(let status):
            retryDeadlines[id] = now + Self.retryInterval
            return .undetermined(status: status)
        }
    }

    public mutating func invalidate(_ id: WindowID) {
        verdicts.removeValue(forKey: id)
        retryDeadlines.removeValue(forKey: id)
    }

    public mutating func invalidateAll() {
        verdicts.removeAll()
        retryDeadlines.removeAll()
    }

    /// Forget windows that are no longer live.
    public mutating func retain(keeping live: Set<WindowID>) {
        verdicts = verdicts.filter { live.contains($0.key) }
        retryDeadlines = retryDeadlines.filter { live.contains($0.key) }
    }

    private mutating func remember(_ verdict: Bool, for id: WindowID) {
        verdicts[id] = verdict
        retryDeadlines.removeValue(forKey: id)
    }
}

public struct TileabilityModeChange: Equatable, Sendable {
    public let id: WindowID
    public let application: String
    public let from: WindowMode
    public let to: WindowMode

    public var logLine: String {
        let reason = to == .floating ? FloatReason.notResizable.rawValue : "resizable"
        return "window mode id=\(id.pid):\(id.elementID) app=\(application) "
            + "from=\(from.rawValue) to=\(to.rawValue) reason=\(reason)"
    }
}

public struct UndeterminedTileabilityProbe: Equatable, Sendable {
    public let id: WindowID
    public let application: String
    public let status: Int

    public var logLine: String {
        "window probe undetermined id=\(id.pid):\(id.elementID) app=\(application) axerror=\(status)"
    }
}

public struct TileabilityReconciliation: Equatable, Sendable {
    public var modes: [WindowID: WindowMode] = [:]
    public var changes: [TileabilityModeChange] = []
    public var undetermined: [UndeterminedTileabilityProbe] = []
}

/// Reflow-time mode resolution. Tiled windows and windows floating only
/// because they were not resizable are (re)checked through the cache: a
/// failing probe demotes to floating(`notResizable`), a passing one promotes
/// back to tiled, and an undetermined one keeps the current mode.
/// Rule/manual/dialog floats and fullscreen are left alone.
/// Returns the mode of every managed window, so nothing is silently omitted,
/// plus each mode change and undetermined probe for the caller to log.
public func reconcileTileability(
    registry: WindowRegistry,
    cache: inout TileabilityCache,
    now: TimeInterval,
    probe: (WindowID) -> TileabilityProbe
) -> TileabilityReconciliation {
    var result = TileabilityReconciliation()
    for window in registry.managedWindows() {
        if window.isMinimized {
            // Out of the layout without a probe (a minimized window's
            // attributes are unreliable); any non-tiled mode filters it.
            result.modes[window.id] = .floating
            continue
        }
        let probed = window.mode == .tiled
            || (window.mode == .floating && window.floatReason == .notResizable)
        guard probed else {
            result.modes[window.id] = window.mode
            continue
        }
        switch cache.resolve(window.id, now: now, probe: { probe(window.id) }) {
        case .tileable:
            if window.mode != .tiled {
                try? registry.setMode(.tiled, for: window.id)
                result.changes.append(modeChange(window, to: .tiled))
            }
            result.modes[window.id] = .tiled
        case .notTileable:
            if window.mode != .floating {
                try? registry.setFloating(.notResizable, for: window.id)
                result.changes.append(modeChange(window, to: .floating))
            }
            result.modes[window.id] = .floating
        case .undetermined(let status):
            result.undetermined.append(UndeterminedTileabilityProbe(
                id: window.id, application: window.application, status: status
            ))
            result.modes[window.id] = window.mode
        case .retryPending:
            result.modes[window.id] = window.mode
        }
    }
    return result
}

private func modeChange(_ window: ManagedWindow, to mode: WindowMode) -> TileabilityModeChange {
    TileabilityModeChange(id: window.id, application: window.application, from: window.mode, to: mode)
}
