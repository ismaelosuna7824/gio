import AppKit
import CoreFoundation
import Darwin
import Foundation
import GioCore
import IOKit

/// TG-03: the private MultitouchSupport calls behind trackpad gestures,
/// resolved at runtime from the system framework (never linked), so a macOS
/// without one of them only turns gestures off. Function shapes as other
/// trackpad tools declare them; nothing here is documented by Apple.
public struct MultitouchSymbols: @unchecked Sendable {
    typealias DeviceCreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias DeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    typealias DeviceStop = @convention(c) (UnsafeMutableRawPointer) -> Int32
    /// (device, contacts, contact count, timestamp in seconds, frame number, refcon)
    typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32, UnsafeMutableRawPointer?
    ) -> Int32
    typealias Register = @convention(c) (UnsafeMutableRawPointer, ContactCallback, UnsafeMutableRawPointer?) -> Void
    typealias Unregister = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void

    static let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    static let names = [
        "MTDeviceCreateList", "MTDeviceStart", "MTDeviceStop",
        "MTRegisterContactFrameCallbackWithRefcon", "MTUnregisterContactFrameCallback",
    ]

    let createList: DeviceCreateList
    let start: DeviceStart
    let stop: DeviceStop
    let register: Register
    let unregister: Unregister

    /// Every symbol through `lookup`; the table only when none is missing.
    static func resolve(_ lookup: (String) -> UnsafeMutableRawPointer?) -> (symbols: MultitouchSymbols?, missing: [String]) {
        let pointers = names.map { lookup($0) }
        let missing = zip(names, pointers).filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty else {
            return (nil, missing)
        }
        return (
            MultitouchSymbols(
                createList: unsafeBitCast(pointers[0]!, to: DeviceCreateList.self),
                start: unsafeBitCast(pointers[1]!, to: DeviceStart.self),
                stop: unsafeBitCast(pointers[2]!, to: DeviceStop.self),
                register: unsafeBitCast(pointers[3]!, to: Register.self),
                unregister: unsafeBitCast(pointers[4]!, to: Unregister.self)
            ),
            []
        )
    }
}

/// One contact in a MultitouchSupport frame: a 96-byte record. Only the
/// identifier, the state and the normalized position are read.
enum MultitouchLayout {
    static let stride = 96
    static let identifier = 16
    static let state = 20
    static let x = 32
    static let y = 36
    /// `makeTouch` (first frame on the surface) and `touching`; hovering,
    /// lifting and out-of-range contacts are not fingers on the surface.
    static let touchingStates: Set<Int32> = [3, 4]
}

/// Copies the fingers on the surface out of a contact frame (normalized
/// position, y up). Runs on MultitouchSupport's callback thread; nothing it
/// returns points into the framework's memory.
func touchFrame(contacts: UnsafeRawPointer?, count: Int, timestamp: Double) -> TouchFrame {
    guard let contacts, count > 0 else {
        return TouchFrame(timestamp: timestamp, contacts: [])
    }
    var touches: [TouchContact] = []
    touches.reserveCapacity(count)
    for index in 0..<count {
        let base = contacts + index * MultitouchLayout.stride
        let state = base.loadUnaligned(fromByteOffset: MultitouchLayout.state, as: Int32.self)
        guard MultitouchLayout.touchingStates.contains(state) else {
            continue
        }
        touches.append(TouchContact(
            id: base.loadUnaligned(fromByteOffset: MultitouchLayout.identifier, as: Int32.self),
            x: Double(base.loadUnaligned(fromByteOffset: MultitouchLayout.x, as: Float.self)),
            y: Double(base.loadUnaligned(fromByteOffset: MultitouchLayout.y, as: Float.self))
        ))
    }
    return TouchFrame(timestamp: timestamp, contacts: touches)
}

/// The C callback MultitouchSupport calls on its own thread for every
/// contact frame of a registered device. It only copies the frame and hands
/// it to the source's `onFrame` (the session's mailbox); it never touches
/// session state.
private func multitouchContactFrame(
    _ device: UnsafeMutableRawPointer?, _ contacts: UnsafeMutableRawPointer?, _ count: Int32,
    _ timestamp: Double, _ frame: Int32, _ refcon: UnsafeMutableRawPointer?
) -> Int32 {
    guard let refcon else {
        return 0
    }
    let source = Unmanaged<MultitouchSource>.fromOpaque(refcon).takeUnretainedValue()
    source.onFrame(touchFrame(contacts: contacts, count: Int(count), timestamp: timestamp))
    return 0
}

/// TG-03: every multitouch device (built-in and Magic Trackpads) reporting
/// contact frames to `onFrame`, on MultitouchSupport's callback thread.
/// `start`/`stop` run on the main thread only. The refcon is unretained:
/// the owner keeps the source alive for the app's life and stops it first.
public final class MultitouchSource: @unchecked Sendable {
    private let symbols: MultitouchSymbols
    fileprivate let onFrame: @Sendable (TouchFrame) -> Void
    /// The device list owns the device references while they are registered.
    private var list: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []

    private init(symbols: MultitouchSymbols, onFrame: @escaping @Sendable (TouchFrame) -> Void) {
        self.symbols = symbols
        self.onFrame = onFrame
    }

    /// Opens MultitouchSupport and resolves its symbols; opens no device.
    /// `missing` names the ones this macOS lacks; the source exists only
    /// when none is missing.
    public static func load(
        onFrame: @escaping @Sendable (TouchFrame) -> Void
    ) -> (source: MultitouchSource?, missing: [String]) {
        let library = dlopen(MultitouchSymbols.path, RTLD_LAZY)
        let (symbols, missing) = MultitouchSymbols.resolve { name in library.flatMap { dlsym($0, name) } }
        guard let symbols else {
            return (nil, missing)
        }
        return (MultitouchSource(symbols: symbols, onFrame: onFrame), [])
    }

    /// Main thread. (Re)registers every device in a fresh device list and
    /// starts it; returns how many devices report frames.
    @discardableResult
    public func start() -> Int {
        stop()
        guard let list = symbols.createList()?.takeRetainedValue() else {
            return 0
        }
        self.list = list
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for index in 0..<CFArrayGetCount(list) {
            guard let value = CFArrayGetValueAtIndex(list, index) else {
                continue
            }
            let device = UnsafeMutableRawPointer(mutating: value)
            symbols.register(device, multitouchContactFrame, refcon)
            _ = symbols.start(device, 0)
            devices.append(device)
        }
        return devices.count
    }

    /// Main thread. Unregisters and stops every device.
    public func stop() {
        for device in devices {
            symbols.unregister(device, multitouchContactFrame)
            _ = symbols.stop(device)
        }
        devices = []
        list = nil
    }
}

/// TG-03: tells the owner when the set of multitouch devices may have
/// changed (a Magic Trackpad connected or gone, the Mac woke up), so it
/// registers again: a device list is a snapshot, and a sleeping Mac's
/// devices stop reporting. Main thread only (`@unchecked Sendable`): IOKit
/// matching notifications on the main queue plus the workspace wake
/// notification.
public final class MultitouchDeviceWatcher: @unchecked Sendable {
    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var wakeObserver: NSObjectProtocol?

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let port = IONotificationPortCreate(kIOMainPortDefault)
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching("AppleMultitouchDevice"), multitouchDevicesChanged, refcon, &iterator
            )
            if status == KERN_SUCCESS {
                // Arms the notification; the devices present now are not news.
                drain(iterator)
                iterators.append(iterator)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.onChange()
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        for iterator in iterators {
            IOObjectRelease(iterator)
        }
        if let port {
            IONotificationPortDestroy(port)
        }
    }

    fileprivate func devicesChanged(_ iterator: io_iterator_t) {
        drain(iterator)
        onChange()
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let object = IOIteratorNext(iterator), object != 0 {
            IOObjectRelease(object)
        }
    }
}

private func multitouchDevicesChanged(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let refcon else {
        return
    }
    Unmanaged<MultitouchDeviceWatcher>.fromOpaque(refcon).takeUnretainedValue().devicesChanged(iterator)
}
