import CoreGraphics
import Foundation

/// MM-04: one display as the `display ...` log line describes it (Cocoa
/// frames, as `NSScreen` reports them).
public struct DisplayLogEntry: Equatable, Sendable {
    public var id: DisplayID
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var scale: CGFloat
    /// Maximum refresh rate in Hz (0 when unknown).
    public var refreshRate: Int
    public var isPrimary: Bool
    /// The user-facing display number (`displaysByNumber`).
    public var number: Int
    public var shownWorkspace: WorkspaceID?
    public var stack: [WorkspaceID]

    public init(
        id: DisplayID, frame: CGRect, visibleFrame: CGRect, scale: CGFloat, refreshRate: Int,
        isPrimary: Bool, number: Int, shownWorkspace: WorkspaceID?, stack: [WorkspaceID]
    ) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.refreshRate = refreshRate
        self.isPrimary = isPrimary
        self.number = number
        self.shownWorkspace = shownWorkspace
        self.stack = stack
    }
}

/// MM-04: the display configuration at startup and after every display
/// change: `displays count=N`, then one line per display in position order
/// (`index` is the 1-based position, `number` the user-facing display
/// number, `shown` the workspace it shows, `stack` its workspaces top to
/// bottom). Numeric ids only.
public func displayConfigurationLog(_ entries: [DisplayLogEntry]) -> [String] {
    var lines = ["displays count=\(entries.count)"]
    for (offset, entry) in entries.enumerated() {
        let shown = entry.shownWorkspace.map { "\($0.rawValue)" } ?? "none"
        let stack = entry.stack.map { "\($0.rawValue)" }.joined(separator: ",")
        lines.append(
            "display index=\(offset + 1) id=\(entry.id.rawValue) frame=\(logRect(entry.frame))"
                + " visible=\(logRect(entry.visibleFrame)) scale=\(logNumber(entry.scale)) hz=\(entry.refreshRate)"
                + " primary=\(entry.isPrimary) number=\(entry.number) shown=\(shown) stack=\(stack)"
        )
    }
    return lines
}

/// MM-04 (debug): the AX/WindowServer flip input after a display change.
public func displayFlipLogLine(primaryHeight: CGFloat, primary: DisplayID?) -> String {
    "display flip primaryHeight=\(logNumber(primaryHeight)) primary=\(primary.map { "\($0.rawValue)" } ?? "none")"
}

private func logRect(_ rect: CGRect) -> String {
    "(\(logNumber(rect.minX)),\(logNumber(rect.minY)),\(logNumber(rect.width)),\(logNumber(rect.height)))"
}

private func logNumber(_ value: CGFloat) -> String {
    value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", Double(value))
}
