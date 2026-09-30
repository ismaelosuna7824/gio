/// Mutable test log shared with `@Sendable` scheduler closures (tests are
/// single-threaded under `ManualScheduler`).
final class Recorder<Value>: @unchecked Sendable {
    private(set) var values: [Value] = []

    func append(_ value: Value) {
        values.append(value)
    }

    var count: Int {
        values.count
    }
}
