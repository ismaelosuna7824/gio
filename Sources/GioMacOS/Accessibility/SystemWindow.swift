import CoreGraphics
import Foundation

/// Snapshot of one standard window seen through public Accessibility APIs.
///
/// This is the long-lived discovery model: later phases map it into the
/// registry (`ManagedWindow`) instead of replacing it. Everything uncertain
/// stays explicit — a missing title or fullscreen flag is reported as
/// `<unknown>` and never blocks listing. Indices are positional within a
/// single enumeration, not stable window identities.
public struct SystemWindow: Equatable, Sendable {
    public let index: Int
    public let pid: pid_t
    public let appName: String
    public let title: String?
    public let frame: CGRect
    public let isFocused: Bool
    public let isMinimized: Bool
    public let isFullscreen: Bool?
    /// NW-02: the app's bundle identifier (`NSRunningApplication`), when known.
    public let bundleID: String?

    public init(
        index: Int,
        pid: pid_t,
        appName: String,
        title: String?,
        frame: CGRect,
        isFocused: Bool,
        isMinimized: Bool,
        isFullscreen: Bool?,
        bundleID: String? = nil
    ) {
        self.bundleID = bundleID
        self.index = index
        self.pid = pid
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isFocused = isFocused
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
    }

    public func describe() -> String {
        var parts = ["\(index)", "pid=\(pid)", "app=\(appName)"]
        if let title, !title.isEmpty {
            parts.append("title=\(title)")
        } else {
            parts.append("title=<unknown>")
        }
        let origin = frame.origin
        let size = frame.size
        parts.append("frame=(\(Int(origin.x)),\(Int(origin.y)),\(Int(size.width)),\(Int(size.height)))")
        if isFocused {
            parts.append("focused")
        }
        if isMinimized {
            parts.append("minimized")
        }
        switch isFullscreen {
        case .some(true):
            parts.append("fullscreen")
        case .some(false):
            break
        case .none:
            parts.append("fullscreen=<unknown>")
        }
        return parts.joined(separator: " ")
    }
}

/// One-line frame rendering shared by CLI output and error messages.
public func describeFrame(_ frame: CGRect) -> String {
    "(\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.size.width)),\(Int(frame.size.height)))"
}
