import Foundation
import GioCore

public final class SpaceCoordinator: @unchecked Sendable {
    public struct Context {
        public var reflowAll: () -> Void
        public var discardPendingAdoptions: () -> Void
        public var adoptFrontmostFocus: () -> Void
        public var log: (LogLevel, String) -> Void

        public init(
            reflowAll: @escaping () -> Void,
            discardPendingAdoptions: @escaping () -> Void,
            adoptFrontmostFocus: @escaping () -> Void,
            log: @escaping (LogLevel, String) -> Void
        ) {
            self.reflowAll = reflowAll
            self.discardPendingAdoptions = discardPendingAdoptions
            self.adoptFrontmostFocus = adoptFrontmostFocus
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

    public func managedSpaceActivityChanged(_ managedActive: Bool) {
        switch gate.update(managedActive: managedActive) {
        case .unchanged:
            break
        case .left:
            context.log(.info, "space foreign; pausing layout")
            context.discardPendingAdoptions()
        case .returned:
            context.log(.info, "space managed; reflow")
            context.adoptFrontmostFocus()
            context.reflowAll()
        }
    }
}
