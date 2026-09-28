import Foundation
import CoreGraphics

public protocol WindowFrameBridge {
    associatedtype Handle
    func checkPermission() throws
    func capture(_ window: WindowID) throws -> (handle: Handle, frame: CGRect)
    func frame(of handle: Handle) throws -> CGRect
    func canTile(_ handle: Handle) throws -> Bool
    func apply(_ handle: Handle, frame: CGRect) throws
}
