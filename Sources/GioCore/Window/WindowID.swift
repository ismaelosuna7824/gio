import Foundation

/// Plan §7 identity: owning PID plus an adapter-assigned element number.
///
/// macOS exposes no stable public window number, so `elementID` is assigned
/// by the adapter layer (e.g. GioMacOS discovery) as a per-process monotonic
/// counter. It is a session identity, never an OS-provided handle: a relaunch
/// re-enumerates and reassigns. `Comparable` gives deterministic ordering for
/// tests and layout input.
public struct WindowID: Hashable, Sendable, Comparable {
    public let pid: pid_t
    public let elementID: UInt64

    public init(pid: pid_t, elementID: UInt64) {
        self.pid = pid
        self.elementID = elementID
    }

    public static func < (lhs: WindowID, rhs: WindowID) -> Bool {
        if lhs.pid != rhs.pid {
            return lhs.pid < rhs.pid
        }
        return lhs.elementID < rhs.elementID
    }
}
