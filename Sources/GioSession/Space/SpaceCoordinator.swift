import Foundation
import GioCore

/// Pauses and resumes window work (`SpaceGate`): when the managed Space is
/// left, and (WC-22) while another window manager runs.
public final class SpaceCoordinator: @unchecked Sendable {
    public struct Context {
        public var reflowAll: () -> Void
        public var discardPendingAdoptions: () -> Void
        /// A full discovery scan: windows that joined the managed Space while
        /// it was inactive (moved there from another Desktop) raise no AX
        /// event, so only a scan finds them.
        public var rescan: () -> Void
        public var adoptFrontmostFocus: () -> Void
        /// WC-22: bring every parked window back on screen (the quit path's
        /// restore) when another window manager takes over.
        public var restoreWindows: () -> Void
        /// FI-17: window work resumes (the managed Space came back, or the
        /// other window manager quit), before the scan and the reflow.
        public var resumed: () -> Void
        public var log: (LogLevel, String) -> Void

        public init(
            reflowAll: @escaping () -> Void,
            discardPendingAdoptions: @escaping () -> Void,
            rescan: @escaping () -> Void,
            adoptFrontmostFocus: @escaping () -> Void,
            restoreWindows: @escaping () -> Void = {},
            resumed: @escaping () -> Void = {},
            log: @escaping (LogLevel, String) -> Void
        ) {
            self.reflowAll = reflowAll
            self.discardPendingAdoptions = discardPendingAdoptions
            self.rescan = rescan
            self.adoptFrontmostFocus = adoptFrontmostFocus
            self.restoreWindows = restoreWindows
            self.resumed = resumed
            self.log = log
        }
    }

    private let context: Context
    private var gate = SpaceGate()

    public init(context: Context) {
        self.context = context
    }

    public var allowsWindowWork: Bool {
        gate.allowsWindowWork
    }

    /// WC-22: the other window managers running, sorted.
    public var conflicts: [String] {
        gate.conflicts
    }

    public func managedSpaceActivityChanged(_ managedActive: Bool) {
        switch gate.update(managedActive: managedActive) {
        case .unchanged:
            break
        case .left:
            context.log(.info, "space foreign; pausing layout")
            context.discardPendingAdoptions()
        case .returned:
            context.log(.info, "space managed; reflow")
            resume()
        }
    }

    /// WC-22: the running window managers other than Gio (sorted names).
    public func windowManagersChanged(_ names: [String]) {
        guard names != gate.conflicts else {
            return
        }
        switch gate.update(conflicts: names) {
        case .left:
            context.log(.info, "window manager running: \(names.joined(separator: ", ")); pausing layout")
            context.discardPendingAdoptions()
            context.restoreWindows()
        case .returned:
            context.log(.info, "window manager gone; reflow")
            resume()
        case .unchanged:
            if !names.isEmpty {
                context.log(.info, "window manager running: \(names.joined(separator: ", "))")
            }
        }
    }

    private func resume() {
        context.resumed()
        context.rescan()
        context.adoptFrontmostFocus()
        context.reflowAll()
    }
}
