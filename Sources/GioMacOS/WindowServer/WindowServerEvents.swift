import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import GioCore

/// WS-01: the private SkyLight calls behind the window-server notifications,
/// resolved at runtime from the system framework (never linked), so a macOS
/// without one of them only turns the notifications off. Function shapes as
/// other window managers declare them; nothing here is documented by Apple.
/// Read-only: nothing here moves, orders or changes a window.
public struct SkyLightEventSymbols: @unchecked Sendable {
    /// (type, payload, payload length, context, connection)
    typealias Handler = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    typealias MainConnection = @convention(c) () -> Int32
    typealias Register = @convention(c) (Int32, Handler, UInt32, UnsafeMutableRawPointer?) -> Int32

    static let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    static let names = ["SLSMainConnectionID", "SLSRegisterConnectionNotifyProc"]

    let mainConnection: MainConnection
    let register: Register

    /// Every symbol through `lookup`; the table only when none is missing.
    static func resolve(
        _ lookup: (String) -> UnsafeMutableRawPointer?
    ) -> (symbols: SkyLightEventSymbols?, missing: [String]) {
        let pointers = names.map { lookup($0) }
        let missing = zip(names, pointers).filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty else {
            return (nil, missing)
        }
        return (
            SkyLightEventSymbols(
                mainConnection: unsafeBitCast(pointers[0]!, to: MainConnection.self),
                register: unsafeBitCast(pointers[1]!, to: Register.self)
            ),
            []
        )
    }
}

/// The C callback SkyLight calls for each registered notification, on the
/// main thread while the app's event loop runs. It only copies the payload
/// and hands the decoded event to the source's `onEvent` (the session's
/// watcher); it never touches session state.
private func windowServerNotification(
    _ type: UInt32, _ data: UnsafeMutableRawPointer?, _ length: Int, _ context: UnsafeMutableRawPointer?,
    _ connection: Int32
) {
    guard let context, let data, length > 0 else {
        return
    }
    let payload = Array(UnsafeRawBufferPointer(start: data, count: length))
    guard let event = decodeWindowServerEvent(type: type, payload: payload) else {
        return
    }
    Unmanaged<WindowServerEventSource>.fromOpaque(context).takeUnretainedValue().onEvent(event)
}

/// WS-01: window created/destroyed notifications for every app, from the
/// window server. `start` runs on the main thread, once. The context pointer
/// is unretained: the owner keeps the source alive for the app's life (the
/// notifications cannot be unregistered one by one on every macOS).
public final class WindowServerEventSource: @unchecked Sendable {
    private let symbols: SkyLightEventSymbols
    fileprivate let onEvent: @Sendable (WindowServerEvent) -> Void
    private var started = false

    private init(symbols: SkyLightEventSymbols, onEvent: @escaping @Sendable (WindowServerEvent) -> Void) {
        self.symbols = symbols
        self.onEvent = onEvent
    }

    /// Opens SkyLight and resolves its symbols; registers nothing. `missing`
    /// names the ones this macOS lacks; the source exists only when none is.
    public static func load(
        onEvent: @escaping @Sendable (WindowServerEvent) -> Void
    ) -> (source: WindowServerEventSource?, missing: [String]) {
        let library = dlopen(SkyLightEventSymbols.path, RTLD_LAZY)
        let (symbols, missing) = SkyLightEventSymbols.resolve { name in library.flatMap { dlsym($0, name) } }
        guard let symbols else {
            return (nil, missing)
        }
        return (WindowServerEventSource(symbols: symbols, onEvent: onEvent), [])
    }

    /// Main thread. Registers every `WindowServerEventType`; returns how many
    /// the window server accepted.
    @discardableResult
    public func start() -> Int {
        guard !started else {
            return 0
        }
        started = true
        let connection = symbols.mainConnection()
        let context = Unmanaged.passUnretained(self).toOpaque()
        return WindowServerEventType.all.filter { type in
            symbols.register(connection, windowServerNotification, type, context) == 0
        }.count
    }
}

/// `_AXUIElementGetWindow` (private, HIServices): the window-server number of
/// an Accessibility window. Resolved once; nil on a macOS without it.
private let axGetWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError)? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
        return nil
    }
    return unsafeBitCast(symbol, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError).self)
}()

/// WS-02: the window-server number of another app's AX window, nil when it
/// cannot be read. Never call it with an element of Gio's own process (rule 4).
public func axWindowNumber(_ element: AXUIElement) -> UInt32? {
    guard let axGetWindow else {
        return nil
    }
    var number: UInt32 = 0
    guard axGetWindow(element, &number) == .success, number != 0 else {
        return nil
    }
    return number
}

/// WS-02: the owner and level of one window-server window (public
/// `CGWindowListCopyWindowInfo`), nil once it is gone.
public func windowServerOwner(number: UInt32) -> WindowServerWindowOwner? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
          let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number }),
          let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
          let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
    else {
        return nil
    }
    return WindowServerWindowOwner(pid: pid, layer: layer)
}
