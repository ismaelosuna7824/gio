import AppKit
import CoreGraphics
import Foundation
import GioCore
import GioMacOS

/// The system state the session reads on its queue: mouse, frontmost app,
/// main screen, running apps and the on-screen window list. One seam so
/// components can be driven by a fake in tests; the live probe reads
/// AppKit/WindowServer exactly as the session always did (no caching).
public protocol SystemProbe: Sendable {
    /// `NSEvent.pressedMouseButtons`: nonzero while any button is down.
    var pressedMouseButtons: Int { get }
    /// `NSEvent.mouseLocation` (Cocoa coordinates).
    var mouseLocation: CGPoint { get }
    /// The frontmost application's pid, if any.
    var frontmostPID: pid_t? { get }
    /// `NSScreen.main?.frame`.
    var mainScreenFrame: CGRect? { get }
    /// `NSScreen.main?.visibleFrame`.
    var mainScreenVisibleFrame: CGRect? { get }
    /// Pids of running apps with the `.regular` activation policy.
    func runningRegularPIDs() -> Set<pid_t>
    /// A running application exists for `pid`.
    func isRunning(_ pid: pid_t) -> Bool
    /// `pid` is a running app with the `.regular` activation policy.
    func isRegularApplication(_ pid: pid_t) -> Bool
    /// The application's localized name, if it is running and has one.
    func applicationName(_ pid: pid_t) -> String?
    /// On-screen windows front to back (one WindowServer query).
    func windowServerWindows(displayHeight: CGFloat) -> [ServerWindow]
}

public extension SystemProbe {
    var isMouseDown: Bool {
        pressedMouseButtons != 0
    }

    /// Height of the main screen, or the session's historical fallback.
    var mainScreenHeight: CGFloat {
        mainScreenFrame?.height ?? 1169
    }

    /// Name for log lines: the app name, or `pid<n>` when unknown.
    func applicationLabel(_ pid: pid_t) -> String {
        applicationName(pid) ?? "pid\(pid)"
    }
}

/// Reads AppKit and the WindowServer on every call (callers decide how
/// often). Stateless, so it is safe from any thread AppKit allows.
public struct LiveSystemProbe: SystemProbe {
    public init() {}

    public var pressedMouseButtons: Int {
        NSEvent.pressedMouseButtons
    }

    public var mouseLocation: CGPoint {
        NSEvent.mouseLocation
    }

    public var frontmostPID: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public var mainScreenFrame: CGRect? {
        NSScreen.main?.frame
    }

    public var mainScreenVisibleFrame: CGRect? {
        NSScreen.main?.visibleFrame
    }

    public func runningRegularPIDs() -> Set<pid_t> {
        Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier)
        )
    }

    public func isRunning(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid) != nil
    }

    public func isRegularApplication(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }

    public func applicationName(_ pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    public func windowServerWindows(displayHeight: CGFloat) -> [ServerWindow] {
        GioMacOS.windowServerWindows(displayHeight: displayHeight)
    }
}
