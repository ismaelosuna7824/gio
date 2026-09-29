import AppKit
import CoreGraphics
import Foundation
import GioCore

/// Virtual keycodes (Carbon `kVK_ANSI_*`, ANSI layout) keyed by the shared
/// key-name vocabulary (`supportedKeyNames`). Hardcoded deliberately: stable
/// for decades, and avoids a Carbon dependency for a few integers. A test
/// keeps this table and the vocabulary identical.
let tapKeyCodes: [String: Int64] = [
    "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
    "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "Equal": 24, "9": 25,
    "7": 26, "Minus": 27, "8": 28, "0": 29, "BracketRight": 30, "O": 31, "U": 32,
    "BracketLeft": 33, "I": 34, "P": 35, "Return": 36, "L": 37, "J": 38, "Quote": 39,
    "K": 40, "Semicolon": 41, "Backslash": 42, "Comma": 43, "Slash": 44, "N": 45,
    "M": 46, "Period": 47, "Tab": 48, "Space": 49, "Grave": 50, "Delete": 51, "Escape": 53,
    "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98,
    "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
    "Home": 115, "PageUp": 116, "End": 119, "PageDown": 121,
    "Left": 123, "Right": 124, "Down": 125, "Up": 126,
]

private let tapKeyNames: [Int64: String] = Dictionary(
    uniqueKeysWithValues: tapKeyCodes.map { ($0.value, $0.key) }
)

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
    switch tapEventAction(for: type) {
    case .reenable(let reason):
        // macOS turned the tap off (slow callback). Without this the keyboard
        // stays dead for the whole session.
        box.reenable(reason)
        return Unmanaged.passUnretained(event)
    case .mouseDown:
        // Observed only, never swallowed. Cocoa coordinates: the space the
        // window frames are kept in.
        box.onMouseDown?(NSEvent.mouseLocation)
        return Unmanaged.passUnretained(event)
    case .mouseMoved:
        box.onMouseMoved?(NSEvent.mouseLocation)
        return Unmanaged.passUnretained(event)
    case .passThrough:
        return Unmanaged.passUnretained(event)
    case .keyDown:
        guard let combo = tapCombo(from: event) else {
            return Unmanaged.passUnretained(event)
        }
        // Returning nil swallows the key. Only exact matches are swallowed, so
        // ordinary typing (including Option-accented characters) passes through
        // untouched — at the cost that WM keys must be unambiguous.
        return box.onCombo(combo) ? nil : Unmanaged.passUnretained(event)
    }
}

final class TapBox: @unchecked Sendable {
    let onCombo: @Sendable (HotkeyCombo) -> Bool
    let onMouseDown: (@Sendable (CGPoint) -> Void)?
    let onMouseMoved: (@Sendable (CGPoint) -> Void)?
    /// The callback (main) and the watchdog (main) both use these; the lock
    /// keeps `stop()` from racing them. Never held across a call out.
    private let lock = NSLock()
    private var port: CFMachPort?
    private var tracker = TapReenableTracker()

    init(
        onCombo: @Sendable @escaping (HotkeyCombo) -> Bool,
        onMouseDown: (@Sendable (CGPoint) -> Void)?,
        onMouseMoved: (@Sendable (CGPoint) -> Void)?
    ) {
        self.onCombo = onCombo
        self.onMouseDown = onMouseDown
        self.onMouseMoved = onMouseMoved
    }

    func attach(_ port: CFMachPort?) {
        lock.lock()
        self.port = port
        lock.unlock()
    }

    /// Switch the tap back on and log it (warn once, debug after).
    func reenable(_ reason: TapReenableReason) {
        lock.lock()
        guard let port else {
            lock.unlock()
            return
        }
        CGEvent.tapEnable(tap: port, enable: true)
        let entry = tracker.record(reason)
        lock.unlock()
        GioLog.record(entry.level, entry.message)
    }

    /// Watchdog tick: re-enable when the tap is off.
    func checkEnabled() {
        lock.lock()
        let enabled = port.map { CGEvent.tapIsEnabled(tap: $0) } ?? true
        lock.unlock()
        if tapWatchdogAction(isEnabled: enabled) == .reenable {
            reenable(.watchdog)
        }
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
    private var watchdog: DispatchSourceTimer?
    private let onCombo: @Sendable (HotkeyCombo) -> Bool
    private let onMouseDown: (@Sendable (CGPoint) -> Void)?
    private let onMouseMoved: (@Sendable (CGPoint) -> Void)?

    /// Whether this tap subscribes to pointer moves (only when a handler was
    /// given; the host passes one only for focus-follows-mouse).
    public var observesMouseMoved: Bool {
        onMouseMoved != nil
    }

    /// `onMouseDown` observes clicks and `onMouseMoved` pointer moves (Cocoa
    /// global location) without swallowing either.
    public init(
        onMouseDown: (@Sendable (CGPoint) -> Void)? = nil,
        onMouseMoved: (@Sendable (CGPoint) -> Void)? = nil,
        onCombo: @Sendable @escaping (HotkeyCombo) -> Bool
    ) {
        self.onCombo = onCombo
        self.onMouseDown = onMouseDown
        self.onMouseMoved = onMouseMoved
    }

    @discardableResult
    public func start() -> Bool {
        guard port == nil else {
            return true
        }
        let box = TapBox(onCombo: onCombo, onMouseDown: onMouseDown, onMouseMoved: onMouseMoved)
        let boxRefcon = Unmanaged.passRetained(box).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: tapEventMask(observingMouseMoved: onMouseMoved != nil),
            callback: tapCallback,
            userInfo: boxRefcon
        ) else {
            Unmanaged<TapBox>.fromOpaque(boxRefcon).release()
            return false
        }
        self.port = port
        box.attach(port)
        self.boxRefcon = boxRefcon
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        startWatchdog(box)
        return true
    }

    /// Every 2 s on main: a tap macOS disabled without telling us is switched
    /// back on. Cheap (one flag read).
    private func startWatchdog(_ box: TapBox) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak box] in
            box?.checkEnabled()
        }
        timer.resume()
        watchdog = timer
    }

    public func stop() {
        watchdog?.cancel()
        watchdog = nil
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        port = nil
        if let boxRefcon {
            let box: TapBox = Unmanaged.fromOpaque(boxRefcon).takeUnretainedValue()
            box.attach(nil)
            Unmanaged<TapBox>.fromOpaque(boxRefcon).release()
            self.boxRefcon = nil
        }
    }

    deinit {
        stop()
    }
}
