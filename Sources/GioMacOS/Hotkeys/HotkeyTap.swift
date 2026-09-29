import AppKit
import CoreGraphics
import Foundation
import GioCore

/// USB HID keycodes for the keys Gio binds (ANSI layout). Hardcoded
/// deliberately: stable for decades, and avoids a Carbon dependency for
/// a few integers.
private let tapKeyNames: [Int64: String] = [
    4: "H", 38: "J", 40: "K", 37: "L",
    18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
    22: "6", 26: "7", 28: "8", 25: "9",
    49: "Space",
    15: "R", 3: "F", 8: "C",
    27: "Minus", 24: "Equal", 33: "BracketLeft", 30: "BracketRight",
]

func tapCombo(from event: CGEvent) -> HotkeyCombo? {
    guard let key = tapKeyNames[event.getIntegerValueField(.keyboardEventKeycode)] else {
        return nil
    }
    var modifiers = Set<HotkeyModifier>()
    let flags = event.flags
    if flags.contains(.maskAlternate) {
        modifiers.insert(.alt)
    }
    if flags.contains(.maskShift) {
        modifiers.insert(.shift)
    }
    if flags.contains(.maskControl) {
        modifiers.insert(.ctrl)
    }
    if flags.contains(.maskCommand) {
        modifiers.insert(.cmd)
    }
    return HotkeyCombo(modifiers: modifiers, key: key)
}

private func tapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let box: TapBox = Unmanaged.fromOpaque(refcon).takeUnretainedValue()
    if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
        // Observed only, never swallowed. Cocoa coordinates: the space the
        // window frames are kept in.
        box.onMouseDown?(NSEvent.mouseLocation)
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }
    guard let combo = tapCombo(from: event) else {
        return Unmanaged.passUnretained(event)
    }
    // Returning nil swallows the key. Only exact matches are swallowed, so
    // ordinary typing (including Option-accented characters) passes through
    // untouched — at the cost that WM keys must be unambiguous.
    return box.onCombo(combo) ? nil : Unmanaged.passUnretained(event)
}

final class TapBox {
    let onCombo: @Sendable (HotkeyCombo) -> Bool
    let onMouseDown: (@Sendable (CGPoint) -> Void)?

    init(
        onCombo: @Sendable @escaping (HotkeyCombo) -> Bool,
        onMouseDown: (@Sendable (CGPoint) -> Void)?
    ) {
        self.onCombo = onCombo
        self.onMouseDown = onMouseDown
    }
}

/// Global key listener. Matches key-downs against combos and reports them;
/// a `true` answer swallows the key so WM bindings never leak into apps.
/// Runs on the main run loop (create and start from the main thread).
/// Fails to start without Accessibility permission — the host requests it
/// first and reports refusal instead of running deaf.
public final class HotkeyTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var boxRefcon: UnsafeMutableRawPointer?
    private let onCombo: @Sendable (HotkeyCombo) -> Bool
    private let onMouseDown: (@Sendable (CGPoint) -> Void)?

    /// `onMouseDown` observes clicks (Cocoa global location) without
    /// swallowing them.
    public init(
        onMouseDown: (@Sendable (CGPoint) -> Void)? = nil,
        onCombo: @Sendable @escaping (HotkeyCombo) -> Bool
    ) {
        self.onCombo = onCombo
        self.onMouseDown = onMouseDown
    }

    @discardableResult
    public func start() -> Bool {
        guard port == nil else {
            return true
        }
        let boxRefcon = Unmanaged.passRetained(TapBox(onCombo: onCombo, onMouseDown: onMouseDown)).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
                .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) },
            callback: tapCallback,
            userInfo: boxRefcon
        ) else {
            Unmanaged<TapBox>.fromOpaque(boxRefcon).release()
            return false
        }
        self.port = port
        self.boxRefcon = boxRefcon
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    public func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        port = nil
        if let boxRefcon {
            Unmanaged<TapBox>.fromOpaque(boxRefcon).release()
            self.boxRefcon = nil
        }
    }

    deinit {
        stop()
    }
}
