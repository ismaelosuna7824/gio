import Foundation

/// WS-01: what the window server reports about one window, decoded from a
/// private SkyLight connection notification (`GioMacOS` registers for them).
/// Window numbers are the window server's own ids (`kCGWindowNumber`).
/// Unlike Accessibility notifications these arrive for every app, whether or
/// not it answers Accessibility.
public enum WindowServerEvent: Equatable, Sendable {
    case created(UInt32)
    case destroyed(UInt32)
    /// WS-03: only for windows Gio subscribed (`SLSRequestNotificationsForWindows`).
    case moved(UInt32)
    case resized(UInt32)
}

/// Notification types, as measured on macOS 27 (throwaway probe, 2026-11-04):
/// a window opening and closing posted 1325 and 1326 with a 12-byte payload;
/// a subscribed window moving or resizing posted 806 and 807 with 4 bytes.
public enum WindowServerEventType {
    public static let windowMoved: UInt32 = 806
    public static let windowResized: UInt32 = 807
    public static let spaceWindowCreated: UInt32 = 1325
    public static let spaceWindowDestroyed: UInt32 = 1326
    public static let all: [UInt32] = [windowMoved, windowResized, spaceWindowCreated, spaceWindowDestroyed]
}

/// Decodes one notification. Created and destroyed carry the space id
/// (UInt64) and then the window number (UInt32); moved and resized the
/// window number alone. Anything shorter, or of another type, is nothing.
public func decodeWindowServerEvent(type: UInt32, payload: [UInt8]) -> WindowServerEvent? {
    func number(at offset: Int) -> UInt32? {
        guard payload.count >= offset + 4 else {
            return nil
        }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(payload[offset + $1]) << (8 * UInt32($1)) }
    }
    switch type {
    case WindowServerEventType.spaceWindowCreated:
        return number(at: 8).map(WindowServerEvent.created)
    case WindowServerEventType.spaceWindowDestroyed:
        return number(at: 8).map(WindowServerEvent.destroyed)
    case WindowServerEventType.windowMoved:
        return number(at: 0).map(WindowServerEvent.moved)
    case WindowServerEventType.windowResized:
        return number(at: 0).map(WindowServerEvent.resized)
    default:
        return nil
    }
}

/// The window-server number of each registered window, recorded at
/// registration, both ways. One number per window.
public struct WindowNumberBook: Equatable, Sendable {
    private var byNumber: [UInt32: WindowID] = [:]
    private var byWindow: [WindowID: UInt32] = [:]

    public init() {}

    public func window(for number: UInt32) -> WindowID? {
        byNumber[number]
    }

    /// WS-03: every recorded number, ascending (the subscription list).
    public var numbers: [UInt32] {
        byNumber.keys.sorted()
    }

    public mutating func record(_ id: WindowID, number: UInt32) {
        forget(id)
        if let previous = byNumber[number] {
            byWindow.removeValue(forKey: previous)
        }
        byNumber[number] = id
        byWindow[id] = number
    }

    public mutating func forget(_ id: WindowID) {
        if let number = byWindow.removeValue(forKey: id) {
            byNumber.removeValue(forKey: number)
        }
    }
}

public enum WindowServerEventAction: Equatable, Sendable {
    /// A window Gio does not know appeared: look again after the grace.
    case checkArrival(UInt32)
    /// A registered window went away: ask for the proof scan of its app
    /// (rule 10: the event alone purges nothing).
    case proveVanished(WindowID)
    /// WS-03: a registered window moved or resized; handled like the AX
    /// event unless one arrived for the same change.
    case frameChanged(WindowID, resized: Bool)
    case ignore
}

public func windowServerEventAction(_ event: WindowServerEvent, book: WindowNumberBook) -> WindowServerEventAction {
    switch event {
    case .created(let number):
        return book.window(for: number) == nil ? .checkArrival(number) : .ignore
    case .destroyed(let number):
        return book.window(for: number).map(WindowServerEventAction.proveVanished) ?? .ignore
    case .moved(let number):
        return book.window(for: number).map { .frameChanged($0, resized: false) } ?? .ignore
    case .resized(let number):
        return book.window(for: number).map { .frameChanged($0, resized: true) } ?? .ignore
    }
}

/// WS-03: how far before a window-server notice an AX event of the same
/// window still counts as covering it (the two arrive through different
/// channels, a few milliseconds apart either way).
public let windowServerFrameSkew: TimeInterval = 0.05

/// WS-03: a notice needs handling only when no AX moved/resized event of
/// that window arrived around or after it: the app posts none for this kind
/// of change. Handling both would count one change twice (snap-backs).
public func windowServerFrameChangeNeedsHandling(noticeAt: TimeInterval, lastAccessibilityEvent: TimeInterval?) -> Bool {
    guard let lastAccessibilityEvent else {
        return true
    }
    return lastAccessibilityEvent < noticeAt - windowServerFrameSkew
}

/// The owner of a window-server window, read when the grace ends.
public struct WindowServerWindowOwner: Equatable, Sendable {
    public let pid: pid_t
    /// Window level; 0 is a normal window (menus, popups and panels sit above).
    public let layer: Int

    public init(pid: pid_t, layer: Int) {
        self.pid = pid
        self.layer = layer
    }
}

/// The app to scan for a window that appeared: only when it is still
/// unregistered after the grace, still on screen at the normal layer, and
/// not one of Gio's own (rule 4).
public func windowServerArrivalScanPID(
    number: UInt32, book: WindowNumberBook, owner: WindowServerWindowOwner?, ownPID: pid_t
) -> pid_t? {
    guard book.window(for: number) == nil, let owner, owner.layer == 0, owner.pid != ownPID else {
        return nil
    }
    return owner.pid
}
