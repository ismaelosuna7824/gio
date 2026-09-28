import ApplicationServices
import AppKit
import GioCore

/// Public WindowServer metadata only; never requests window images or screen capture access.
public enum SpaceCGMetadata {
    public static func parse(_ rows: [[String: Any]]) -> [SpaceWindowEligibility.CGWindow] {
        rows.compactMap { row in
            guard let number = row[kCGWindowOwnerPID as String] as? NSNumber,
                  number.intValue > 0 else { return nil }
            let bounds = row[kCGWindowBounds as String] as? [String: Any]
            let frame = bounds.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return .init(pid: number.intValue, title: row[kCGWindowName as String] as? String,
                         frame: frame)
        }
    }
}

public enum SpaceWindowSnapshotError: Error, Equatable {
    case unavailableCGMetadata
    case incompletePID(pid_t)
    case staleSnapshot
    case incompleteCGMetadata
}

/// Retained handles are not registered in the bridge. The caller rechecks generation before use.
public struct SpaceWindowSnapshot {
    public struct Window {
        public let id: WindowID
        public let element: AXUIElement
        public let pid: pid_t
        public let title: String
        public let frame: CGRect
        public let displayBounds: CGRect?

        public var candidate: SpaceWindowEligibility.AXCandidate {
            .init(windowID: id, pid: Int(pid), title: title, frame: frame,
                  displayBounds: displayBounds)
        }
    }

    public let generation: UInt64
    public let windows: [Window]
    public let onScreen: [SpaceWindowEligibility.CGWindow]

    /// The injected enumerator must return every standard window for the PID, or throw.
    /// This seam supports metadata-only tests without invoking AX, TCC or the GUI.
    public static func assemble(generation: UInt64, currentGeneration: () -> UInt64,
                                readCG: () throws -> [[String: Any]], regularPIDs: Set<pid_t>,
                                enumerate: (pid_t) throws -> [Window]) throws -> SpaceWindowSnapshot {
        guard currentGeneration() == generation else { throw SpaceWindowSnapshotError.staleSnapshot }
        let rows = try readCG()
        let firstFingerprint = try fingerprint(rows, regularPIDs: regularPIDs)
        let cg = SpaceCGMetadata.parse(rows)
        let pids = Set(cg.map { pid_t($0.pid) }).intersection(regularPIDs)
        var windows: [Window] = []
        for pid in pids.sorted() {
            do {
                let found = try enumerate(pid)
                guard found.allSatisfy({ $0.pid == pid && !$0.title.isEmpty &&
                    $0.frame.width > 0 && $0.frame.height > 0 &&
                    [$0.frame.minX, $0.frame.minY, $0.frame.maxX, $0.frame.maxY].allSatisfy(\.isFinite)
                }) else { throw SpaceWindowSnapshotError.incompletePID(pid) }
                windows.append(contentsOf: found)
            } catch { throw SpaceWindowSnapshotError.incompletePID(pid) }
        }
        // A second bounded public-metadata read detects transitions even when the notification
        // has not yet advanced the caller's epoch. It is not an authoritative Space identity.
        let second = try readCG()
        let secondFingerprint = try fingerprint(second, regularPIDs: regularPIDs)
        guard currentGeneration() == generation, firstFingerprint == secondFingerprint else {
            throw SpaceWindowSnapshotError.staleSnapshot
        }
        return SpaceWindowSnapshot(generation: generation, windows: windows, onScreen: cg)
    }

    private struct Fingerprint: Hashable {
        let id: UInt32
        let pid: Int
        let title: String
        let frame: CGRect
    }

    private static func fingerprint(_ rows: [[String: Any]], regularPIDs: Set<pid_t>) throws -> Set<Fingerprint> {
        var seenIDs: Set<UInt32> = []
        var entries: Set<Fingerprint> = []
        for row in rows {
            guard let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  regularPIDs.contains(pid.int32Value) else { continue }
            guard let id = row[kCGWindowNumber as String] as? NSNumber,
                  id.int64Value > 0, id.int64Value <= UInt32.max,
                  let title = row[kCGWindowName as String] as? String, !title.isEmpty,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 0, frame.height > 0,
                  [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite),
                  seenIDs.insert(id.uint32Value).inserted else {
                throw SpaceWindowSnapshotError.incompleteCGMetadata
            }
            entries.insert(Fingerprint(id: id.uint32Value, pid: pid.intValue,
                                       title: title, frame: frame))
        }
        return entries
    }

    public static func capture(generation: UInt64, currentGeneration: () -> UInt64,
                               discovery: WindowDiscovery) throws -> SpaceWindowSnapshot {
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        return try assemble(generation: generation, currentGeneration: currentGeneration,
                            readCG: {
            guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else {
                throw SpaceWindowSnapshotError.unavailableCGMetadata
            }
            return raw
        }, regularPIDs: pids) { pid in
            try discovery.snapshotWindows(pid: pid)
        }
    }
}
