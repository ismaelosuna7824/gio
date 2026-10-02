public struct SpaceGate: Equatable, Sendable {
    public enum Transition: Equatable, Sendable {
        case unchanged
        case left
        case returned
    }

    public private(set) var isManagedActive: Bool

    public init(isManagedActive: Bool = true) {
        self.isManagedActive = isManagedActive
    }

    public var allowsWindowWork: Bool {
        isManagedActive
    }

    public mutating func update(managedActive: Bool) -> Transition {
        guard managedActive != isManagedActive else {
            return .unchanged
        }
        isManagedActive = managedActive
        return managedActive ? .returned : .left
    }
}
