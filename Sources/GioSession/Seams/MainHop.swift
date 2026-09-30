import Dispatch

/// Runs a block on the main thread later. Live: `mainQueueHop`
/// (`DispatchQueue.main.async`); tests collect the blocks and drain them.
public typealias MainHop = (@escaping @Sendable () -> Void) -> Void

public func mainQueueHop(_ block: @escaping @Sendable () -> Void) {
    DispatchQueue.main.async(execute: block)
}
