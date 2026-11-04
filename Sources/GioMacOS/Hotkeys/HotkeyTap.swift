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

/// DA-07: the key name for a virtual keycode, shared by the shortcut
/// recorder (an `NSEvent` in the app) and the tap; nil outside the vocabulary.
public func hotkeyKeyName(forKeyCode keyCode: Int64) -> String? {
    tapKeyNames[keyCode]
}

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

/// PF-AB: an event's location (global display space, top-left origin of the
/// primary display) in Cocoa coordinates, the space window frames are kept
/// in. Thread-safe, unlike `NSEvent.mouseLocation` on the tap thread.
func tapCocoaLocation(of event: CGEvent, primaryHeight: CGFloat) -> CGPoint {
    let point = event.location
    return CGPoint(x: point.x, y: primaryHeight - point.y)
}

private func tapCocoaLocation(of event: CGEvent) -> CGPoint {
    tapCocoaLocation(of: event, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
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
        box.onMouseDown?(tapCocoaLocation(of: event))
        return Unmanaged.passUnretained(event)
    case .mouseMoved:
        box.onMouseMoved?(tapCocoaLocation(of: event))
        return Unmanaged.passUnretained(event)
    case .passThrough:
        return Unmanaged.passUnretained(event)
    case .keyDown:
        guard let combo = tapCombo(from: event) else {
            box.onKeyDown?()
            return Unmanaged.passUnretained(event)
        }
        // Returning nil swallows the key. Only exact matches are swallowed, so
        // ordinary typing (including Option-accented characters) passes through
        // untouched — at the cost that WM keys must be unambiguous.
        if box.onCombo(combo) {
            return nil
        }
        // SM-09: a key that reached an app is typing (observed, never swallowed).
        box.onKeyDown?()
        return Unmanaged.passUnretained(event)
    }
}

final class TapBox: @unchecked Sendable {
    let onCombo: @Sendable (HotkeyCombo) -> Bool
    let onMouseDown: (@Sendable (CGPoint) -> Void)?
    let onMouseMoved: (@Sendable (CGPoint) -> Void)?
    let onKeyDown: (@Sendable () -> Void)?
    /// The callback (tap thread) and the watchdog (main) both use these; the
    /// lock keeps `stop()` from racing them. Never held across a call out.
    private let lock = NSLock()
    private var port: CFMachPort?
    private var tracker = TapReenableTracker()

    init(
        onCombo: @Sendable @escaping (HotkeyCombo) -> Bool,
        onMouseDown: (@Sendable (CGPoint) -> Void)?,
        onMouseMoved: (@Sendable (CGPoint) -> Void)?,
        onKeyDown: (@Sendable () -> Void)? = nil
    ) {
        self.onCombo = onCombo
        self.onMouseDown = onMouseDown
        self.onMouseMoved = onMouseMoved
        self.onKeyDown = onKeyDown
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

/// PF-AB: the tap's own thread and run loop. On the main run loop every
/// keystroke and click of every app waited for Gio's main thread (overlay
/// frames, AX callbacks, SwiftUI): any hitch there was felt system-wide as
/// input lag. The thread owns the box's retain and releases it after its
/// run loop stopped, so no callback can outlive it.
private final class TapThread: Thread, @unchecked Sendable {
    private let source: CFRunLoopSource
    private let boxRefcon: UnsafeMutableRawPointer
    private let ready = DispatchSemaphore(value: 0)
    /// Guards `runLoop`.
    private let lock = NSLock()
    private var runLoop: CFRunLoop?

    init(source: CFRunLoopSource, boxRefcon: UnsafeMutableRawPointer) {
        self.source = source
        self.boxRefcon = boxRefcon
        super.init()
        name = "gio.hotkey-tap"
        qualityOfService = .userInteractive
    }

    override func main() {
        let current = CFRunLoopGetCurrent()
        lock.lock()
        runLoop = current
        lock.unlock()
        CFRunLoopAddSource(current, source, .commonModes)
        ready.signal()
        CFRunLoopRun()
        CFRunLoopRemoveSource(current, source, .commonModes)
        Unmanaged<TapBox>.fromOpaque(boxRefcon).release()
    }

    /// Starts the thread and returns once its run loop has the source.
    func startAndWait() {
        start()
        ready.wait()
    }

    /// Any thread. The run loop returns after the callback in progress.
    func stopRunLoop() {
        lock.lock()
        let runLoop = runLoop
        lock.unlock()
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }
}

/// Global key listener. Matches key-downs against combos and reports them;
/// a `true` answer swallows the key so WM bindings never leak into apps.
/// Create, start and stop it from the main thread; its callbacks run on
/// its own thread (PF-AB) and must be thread-safe and cheap. Fails to start
/// without Accessibility permission — the host requests it first and
/// reports refusal instead of running deaf.
public final class HotkeyTap {
    private var port: CFMachPort?
    private var thread: TapThread?
    private weak var box: TapBox?
    private var watchdog: DispatchSourceTimer?
    private let onCombo: @Sendable (HotkeyCombo) -> Bool
    private let onMouseDown: (@Sendable (CGPoint) -> Void)?
    private let onMouseMoved: (@Sendable (CGPoint) -> Void)?
    private let onKeyDown: (@Sendable () -> Void)?

    /// Whether this tap subscribes to pointer moves (only when a handler was
    /// given; the host passes one only for focus-follows-mouse).
    public var observesMouseMoved: Bool {
        onMouseMoved != nil
    }

    /// `onMouseDown` observes clicks and `onMouseMoved` pointer moves (Cocoa
    /// global location) without swallowing either. `onKeyDown` observes
    /// every key-down that reaches an app (not the swallowed WM combos).
    /// All four run on the tap thread (SM-09, PF-AB).
    public init(
        onMouseDown: (@Sendable (CGPoint) -> Void)? = nil,
        onMouseMoved: (@Sendable (CGPoint) -> Void)? = nil,
        onKeyDown: (@Sendable () -> Void)? = nil,
        onCombo: @Sendable @escaping (HotkeyCombo) -> Bool
    ) {
        self.onCombo = onCombo
        self.onMouseDown = onMouseDown
        self.onMouseMoved = onMouseMoved
        self.onKeyDown = onKeyDown
    }

    @discardableResult
    public func start() -> Bool {
        guard port == nil else {
            return true
        }
        let box = TapBox(onCombo: onCombo, onMouseDown: onMouseDown, onMouseMoved: onMouseMoved, onKeyDown: onKeyDown)
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
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            Unmanaged<TapBox>.fromOpaque(boxRefcon).release()
            return false
        }
        self.port = port
        self.box = box
        box.attach(port)
        let thread = TapThread(source: source, boxRefcon: boxRefcon)
        thread.startAndWait()
        self.thread = thread
        CGEvent.tapEnable(tap: port, enable: true)
        startWatchdog(box)
        return true
    }

    /// Every 30 s on main (generous leeway so the system can coalesce the
    /// wakeup): a tap macOS disabled without telling us is switched back on.
    /// The callback already re-enables on timeout/user-input disable, so this
    /// is only a safety net. Cheap (one flag read).
    private func startWatchdog(_ box: TapBox) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
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
            CFMachPortInvalidate(port)
        }
        port = nil
        box?.attach(nil)
        box = nil
        // The thread releases the box once its run loop returned.
        thread?.stopRunLoop()
        thread = nil
    }

    deinit {
        stop()
    }
}
