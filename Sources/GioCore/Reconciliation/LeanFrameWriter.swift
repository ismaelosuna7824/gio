import CoreGraphics
import Foundation

/// Which attributes a frame change really needs (MO-02). Writing only what
/// changed halves the Accessibility round trips of a typical scroll step,
/// where most windows just slide sideways at a constant size.
public enum FrameWritePlan: Equatable, Sendable {
    case none
    case positionOnly
    case sizeOnly
    /// Growing: a size-first write of a large frame from a small position
    /// overflows the display and macOS clamps it, so position leads.
    case positionThenSize
    /// Shrinking (or size unchanged in width/height growth): size leads.
    case sizeThenPosition
}

public func planFrameWrite(current: CGRect, target: CGRect, tolerance: CGFloat = 1) -> FrameWritePlan {
    let positionChanged = abs(current.origin.x - target.origin.x) > tolerance
        || abs(current.origin.y - target.origin.y) > tolerance
    let sizeChanged = abs(current.size.width - target.size.width) > tolerance
        || abs(current.size.height - target.size.height) > tolerance
    switch (positionChanged, sizeChanged) {
    case (false, false):
        return .none
    case (true, false):
        return .positionOnly
    case (false, true):
        return .sizeOnly
    case (true, true):
        let growing = target.size.width > current.size.width + tolerance
            || target.size.height > current.size.height + tolerance
        return growing ? .positionThenSize : .sizeThenPosition
    }
}

/// One AX call per method. A nil read means the element is gone.
public protocol FrameAttributeIO {
    func readPosition() throws -> CGPoint?
    func readSize() throws -> CGSize?
    func writePosition(_ point: CGPoint) throws
    func writeSize(_ size: CGSize) throws
}

public enum FrameWriteError: Error, Equatable {
    /// The window did not land on the target (or vanished: `.zero`).
    case mismatch(actual: CGRect)
}

/// Writes `target` given the caller's knowledge of `current`: no pre-read,
/// no settable probe, only changed attributes, and — when `verify` — a
/// read-back of just those attributes. Everything is in one coordinate
/// space (the caller's); the IO speaks it too.
public func writeFrame(
    current: CGRect, target: CGRect, verify: Bool, tolerance: CGFloat = 1, io: some FrameAttributeIO
) throws {
    let plan = planFrameWrite(current: current, target: target, tolerance: tolerance)
    switch plan {
    case .none:
        return
    case .positionOnly:
        try io.writePosition(target.origin)
    case .sizeOnly:
        try io.writeSize(target.size)
    case .positionThenSize:
        try io.writePosition(target.origin)
        try io.writeSize(target.size)
    case .sizeThenPosition:
        try io.writeSize(target.size)
        try io.writePosition(target.origin)
    }
    guard verify else {
        return
    }
    let checksPosition = plan != .sizeOnly
    let checksSize = plan != .positionOnly
    var actual = current
    if checksPosition {
        guard let position = try io.readPosition() else {
            throw FrameWriteError.mismatch(actual: .zero)
        }
        actual.origin = position
    }
    if checksSize {
        guard let size = try io.readSize() else {
            throw FrameWriteError.mismatch(actual: .zero)
        }
        actual.size = size
    }
    let landed = abs(actual.origin.x - target.origin.x) <= tolerance
        && abs(actual.origin.y - target.origin.y) <= tolerance
        && abs(actual.size.width - target.size.width) <= tolerance
        && abs(actual.size.height - target.size.height) <= tolerance
    guard landed else {
        throw FrameWriteError.mismatch(actual: actual)
    }
}
