import Foundation
import CoreGraphics

/// Only a verified AX frame mismatch may offer geometry for a constrained-size retry.
public protocol WindowFrameMismatch: Error {
    var mismatchedFrames: (requested: CGRect, actual: CGRect)? { get }
}

public enum ConstrainedFrame {
    public static func isPlausible(requested: CGRect, actual: CGRect) -> Bool {
        let values = [requested.minX, requested.minY, requested.maxX, requested.maxY,
                      requested.width, requested.height, actual.minX, actual.minY,
                      actual.maxX, actual.maxY, actual.width, actual.height]
        guard values.allSatisfy(\.isFinite), requested.width > 0, requested.height > 0,
              actual.width > 0, actual.height > 0,
              abs(requested.minX - actual.minX) <= 1,
              abs(requested.minY - actual.minY) <= 1 else { return false }
        let width = actual.width - requested.width
        let height = actual.height - requested.height
        return width >= -1 && height >= -1 && (width > 1 || height > 1)
    }
}

public protocol WindowFrameBridge {
    associatedtype Handle
    func checkPermission() throws
    func capture(_ window: LegacyWindowID) throws -> (handle: Handle, frame: CGRect)
    func frame(of handle: Handle) throws -> CGRect
    func canTile(_ handle: Handle) throws -> Bool
    func apply(_ handle: Handle, frame: CGRect) throws
}
