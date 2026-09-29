import Foundation

/// Per-window memo of the "can this window be resized?" probe. The probe
/// costs several Accessibility calls, so reflows reuse the verdict until the
/// window is (re)registered, an attribute/resize event or an explicit resync
/// invalidates it. Pure value type: the host owns one and wires the events.
public struct TileabilityCache: Sendable {
    private var verdicts: [WindowID: Bool] = [:]

    public init() {}

    public func verdict(for id: WindowID) -> Bool? {
        verdicts[id]
    }

    /// Cached verdict, or run `probe` once and remember its answer.
    public mutating func resolve(_ id: WindowID, probe: () -> Bool) -> Bool {
        if let cached = verdicts[id] {
            return cached
        }
        let fresh = probe()
        verdicts[id] = fresh
        return fresh
    }

    public mutating func invalidate(_ id: WindowID) {
        verdicts.removeValue(forKey: id)
    }

    public mutating func invalidateAll() {
        verdicts.removeAll()
    }

    /// Forget windows that are no longer live.
    public mutating func retain(keeping live: Set<WindowID>) {
        verdicts = verdicts.filter { live.contains($0.key) }
    }
}

/// Reflow-time mode resolution. Tiled windows and windows floating only
/// because they were not resizable are (re)checked through the cache: a
/// failing probe demotes to floating(`notResizable`), a passing one promotes
/// back to tiled. Rule/manual/dialog floats and fullscreen are left alone.
/// Returns the mode of every managed window, so nothing is silently omitted.
public func reconcileTileability(
    registry: WindowRegistry,
    cache: inout TileabilityCache,
    probe: (WindowID) -> Bool
) -> [WindowID: WindowMode] {
    var modes: [WindowID: WindowMode] = [:]
    for window in registry.managedWindows() {
        let probed = window.mode == .tiled
            || (window.mode == .floating && window.floatReason == .notResizable)
        guard probed else {
            modes[window.id] = window.mode
            continue
        }
        if cache.resolve(window.id, probe: { probe(window.id) }) {
            if window.mode != .tiled {
                try? registry.setMode(.tiled, for: window.id)
            }
            modes[window.id] = .tiled
        } else {
            if window.mode != .floating {
                try? registry.setFloating(.notResizable, for: window.id)
            }
            modes[window.id] = .floating
        }
    }
    return modes
}
