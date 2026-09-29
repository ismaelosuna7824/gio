import Foundation

/// A value one queue publishes and any thread reads without waiting on that
/// queue. The main thread reads session snapshots through this so it never
/// blocks behind a slow reflow. The lock is held only to copy the value.
public final class PublishedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ initial: Value) {
        value = initial
    }

    public func publish(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    public func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
