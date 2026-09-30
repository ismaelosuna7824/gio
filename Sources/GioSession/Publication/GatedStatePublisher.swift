import GioCore

/// Deduplicating gate for a published value (e.g. the menu bar's
/// `BarStateGate`): true when `value` must be published.
public protocol PublicationGate {
    associatedtype Value
    mutating func accept(_ value: Value) -> Bool
}

/// PA-02: a value pushed (deduplicated) from the session queue instead of
/// being polled. The latest accepted value is readable from any thread
/// without waiting on the queue; observers get it on the main thread.
/// `publish()` runs on the session queue only.
public final class GatedStatePublisher<Gate: PublicationGate>: @unchecked Sendable where Gate.Value: Sendable {
    public struct Context {
        /// Somebody listens (the app set its hook); nothing is built otherwise.
        public var isObserved: () -> Bool
        public var makeValue: () -> Gate.Value
        public var mainHop: MainHop
        public var deliver: (Gate.Value) -> Void

        public init(
            isObserved: @escaping () -> Bool, makeValue: @escaping () -> Gate.Value,
            mainHop: @escaping MainHop, deliver: @escaping (Gate.Value) -> Void
        ) {
            self.isObserved = isObserved
            self.makeValue = makeValue
            self.mainHop = mainHop
            self.deliver = deliver
        }
    }

    private let context: Context
    private var gate: Gate
    private let cell: PublishedValue<Gate.Value>

    public init(gate: Gate, initial: Gate.Value, context: Context) {
        self.gate = gate
        self.cell = PublishedValue(initial)
        self.context = context
    }

    /// Any thread: the last published value.
    public func read() -> Gate.Value {
        cell.read()
    }

    /// Cheap no-op when nothing changed.
    public func publish() {
        guard context.isObserved() else {
            return
        }
        let value = context.makeValue()
        guard gate.accept(value) else {
            return
        }
        cell.publish(value)
        context.mainHop { [weak self] in
            self?.context.deliver(value)
        }
    }
}
