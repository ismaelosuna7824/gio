import CoreGraphics
import Foundation

// TG-12: Gio is in the scroll-event path only while tap-to-swipe is armed.
// The hotkey tap never subscribes to scroll events (every scroll of every
// app would pass through Gio's active tap). Instead a separate scroll-only
// tap exists while `[gestures] tap-to-swipe` is on, created disabled: a
// disabled tap is not in the event path. Arming enables it
// (`CGEvent.tapEnable`, one call, no thread or port setup at the moment the
// fingers start) and disarming disables it again. Creating and destroying a
// tap per arming was rejected: tap creation and its thread cost
// milliseconds on main exactly when the first stroke begins, and a missed
// teardown would leave a live tap behind; a stale enable here is harmless
// because the callback still checks the deadline and switches itself off at
// the first scroll event past it.

/// What the scroll tap's callback does with one event.
enum ScrollTapEventAction: Equatable {
    /// Armed: drop the scroll event.
    case swallow
    case pass
    /// Not armed (an enable outlived the deadline): pass it and switch off.
    case passAndDisable
    /// macOS turned the tap off while armed.
    case reenable
    /// macOS turned the tap off while not armed: leave it off.
    case stayDisabled
}

func scrollTapEventAction(for type: CGEventType, swallowing: Bool) -> ScrollTapEventAction {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        return swallowing ? .reenable : .stayDisabled
    case .scrollWheel:
        return swallowing ? .swallow : .passAndDisable
    default:
        return .pass
    }
}

/// Scroll events only.
func scrollTapEventMask() -> CGEventMask {
    CGEventMask(1) << CGEventType.scrollWheel.rawValue
}

public enum ScrollTapLifecycle: Equatable, Sendable {
    case start
    case stop
    case none
}

/// The scroll tap exists exactly while tap-to-swipe is on.
public func scrollTapLifecycle(running: Bool, wanted: Bool) -> ScrollTapLifecycle {
    switch (running, wanted) {
    case (false, true): return .start
    case (true, false): return .stop
    default: return .none
    }
}

final class ScrollTapBox: @unchecked Sendable {
    let swallows: @Sendable () -> Bool
    /// Guards `port` (tap thread, session queue, main).
    private let lock = NSLock()
    private var port: CFMachPort?

    init(swallows: @escaping @Sendable () -> Bool) {
        self.swallows = swallows
    }

    func attach(_ port: CFMachPort?) {
        lock.withLock { self.port = port }
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            if let port {
                CGEvent.tapEnable(tap: port, enable: enabled)
            }
        }
    }
}

private func scrollTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let box: ScrollTapBox = Unmanaged.fromOpaque(refcon).takeUnretainedValue()
    switch scrollTapEventAction(for: type, swallowing: box.swallows()) {
    case .swallow:
        return nil
    case .pass, .stayDisabled:
        return Unmanaged.passUnretained(event)
    case .passAndDisable:
        box.setEnabled(false)
        return Unmanaged.passUnretained(event)
    case .reenable:
        box.setEnabled(true)
        return Unmanaged.passUnretained(event)
    }
}

/// TG-12: the scroll-only tap that swallows scrolling while tap-to-swipe is
/// armed. `start`/`stop` on the main thread; `setEnabled` from any thread
/// (the session queue, when arming flips). `swallows` runs on the tap's own
/// thread for every event it sees and must be cheap and thread-safe.
public final class ScrollSuppressionTap: @unchecked Sendable {
    private let swallows: @Sendable () -> Bool
    /// Guards `box`, `port` and `thread`.
    private let lock = NSLock()
    private var box: ScrollTapBox?
    private var port: CFMachPort?
    private var thread: TapThread?

    public init(swallows: @escaping @Sendable () -> Bool) {
        self.swallows = swallows
    }

    public var isRunning: Bool {
        lock.withLock { box != nil }
    }

    /// Main thread. Creates the tap disabled (out of the event path); it is
    /// enabled at once only when already armed.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else {
            return true
        }
        let box = ScrollTapBox(swallows: swallows)
        let refcon = Unmanaged.passRetained(box).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: scrollTapEventMask(),
            callback: scrollTapCallback,
            userInfo: refcon
        ) else {
            Unmanaged<ScrollTapBox>.fromOpaque(refcon).release()
            return false
        }
        CGEvent.tapEnable(tap: port, enable: false)
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            Unmanaged<ScrollTapBox>.fromOpaque(refcon).release()
            return false
        }
        box.attach(port)
        let thread = TapThread(source: source, boxRefcon: refcon, name: "gio.scroll-tap") {
            Unmanaged<ScrollTapBox>.fromOpaque($0).release()
        }
        thread.startAndWait()
        lock.withLock {
            self.box = box
            self.port = port
            self.thread = thread
        }
        if swallows() {
            box.setEnabled(true)
        }
        return true
    }

    /// Any thread: in or out of the event path.
    public func setEnabled(_ enabled: Bool) {
        let box = lock.withLock { self.box }
        box?.setEnabled(enabled)
    }

    /// Main thread (setting off, shutdown).
    public func stop() {
        let (box, port, thread) = lock.withLock {
            defer {
                self.box = nil
                self.port = nil
                self.thread = nil
            }
            return (self.box, self.port, self.thread)
        }
        box?.attach(nil)
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        // The thread releases the box once its run loop returned.
        thread?.stopRunLoop()
    }

    deinit {
        stop()
    }
}
