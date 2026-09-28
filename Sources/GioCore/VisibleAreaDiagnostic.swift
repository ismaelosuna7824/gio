import CoreGraphics

/// Snapshot of one display's visible-area inputs for tiling-failure diagnostics.
/// Pure value type with no AppKit dependency so it stays unit-testable.
/// Geometry numbers only — never window titles, app names, or PIDs.
public struct VisibleAreaDiagnostic {
    public let displayID: String
    public let displayBounds: CGRect
    public let screenFrame: CGRect
    public let visibleFrame: CGRect
    public let cachedUsable: CGRect?

    public init(displayID: String, displayBounds: CGRect,
                screenFrame: CGRect, visibleFrame: CGRect, cachedUsable: CGRect? = nil) {
        self.displayID = displayID
        self.displayBounds = displayBounds
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.cachedUsable = cachedUsable
    }

    /// Freshly converted usable area from live inputs, independent of any cache.
    public var usable: CGRect? {
        DisplayUsableBounds.convert(screenFrame: screenFrame,
                                    visibleFrame: visibleFrame, displayBounds: displayBounds)
    }

    /// One-line human-readable summary, e.g.:
    /// `VisibleArea display=1 bounds=(0, 0, 1512, 944) screen=(0, 0, 1512, 944)
    ///  visible=(0, 25, 1512, 871) usable=(0, 48, 1512, 871) cached=(8, 608, 888, 553) match=drift`
    public func summary() -> String {
        "VisibleArea display=\(displayID) bounds=\(Self.format(displayBounds))" +
        " screen=\(Self.format(screenFrame)) visible=\(Self.format(visibleFrame))" +
        " usable=\(usable.map(Self.format) ?? "nil")" +
        " cached=\(cachedUsable.map(Self.format) ?? "nil") match=\(matchToken)"
    }

    private var matchToken: String {
        guard let cached = cachedUsable else { return "nocache" }
        return usable == cached ? "same" : "drift"
    }

    static func format(_ rect: CGRect) -> String {
        "(\(num(rect.minX)), \(num(rect.minY)), \(num(rect.width)), \(num(rect.height)))"
    }

    private static func num(_ value: CGFloat) -> String {
        value.isFinite && value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }
}
