import CoreGraphics
import Foundation
import GioCore

/// MM-04: a connected display as the menu bar lists it (read from
/// `NSScreen` on the main thread).
public struct MenuDisplay: Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var name: String

    public init(id: UInt32, frame: CGRect, name: String) {
        self.id = id
        self.frame = frame
        self.name = name
    }
}

/// One row of the menu bar's Move to Display submenu.
public struct MoveToDisplayItem: Equatable, Sendable {
    /// The user-facing display number (`displaysByNumber`).
    public var number: Int
    public var title: String
    /// The display showing the focused window's workspace.
    public var isCurrent: Bool
    public var isEnabled: Bool

    /// The IPC verb the item sends (also `> move-window-to-display N`).
    public var argv: [String] {
        ["move-window-to-display", "\(number)"]
    }
}

/// MM-04: the Move to Display submenu: every display by number and name
/// (1 is the main display, the others in position order), the current one
/// checked and disabled. Empty with a single display; every row disabled
/// without a focused window.
public func moveToDisplayItems(displays: [MenuDisplay], current: UInt32?, hasFocusedWindow: Bool) -> [MoveToDisplayItem] {
    guard displays.count > 1 else {
        return []
    }
    let byID = Dictionary(displays.map { (DisplayID($0.id), $0) }, uniquingKeysWith: { first, _ in first })
    return displaysByNumber(byID.mapValues(\.frame)).enumerated().compactMap { offset, id in
        guard let display = byID[id] else {
            return nil
        }
        let isCurrent = display.id == current
        return MoveToDisplayItem(
            number: offset + 1, title: "\(offset + 1)  \(display.name)",
            isCurrent: isCurrent, isEnabled: hasFocusedWindow && !isCurrent
        )
    }
}
