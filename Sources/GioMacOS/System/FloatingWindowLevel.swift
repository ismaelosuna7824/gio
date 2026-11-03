import CoreGraphics
import Foundation
import GioCore

/// WC-19: a floating window stays above the tiled strip, the way niri keeps
/// its floating layer. macOS decides the order between apps by activation, so
/// the only way to pin another app's window is its window-server level — a
/// private call (`CGSSetWindowLevel`), resolved with `dlopen` exactly like the
/// MultitouchSupport read (TG-01). Gio never assumes it works: every change is
/// read back from the public window list, and a system that ignores it leaves
/// the window where it was (the caller logs `floating level refused` once).
///
/// Level: `normal + 2`. Above the dim's panels (`normal + 1`), below the focus
/// ring (`.floating`, 3) and every Gio panel.
public final class FloatingWindowLevel {
    public enum Outcome: Equatable, Sendable {
        /// The window server reports the new level.
        case applied
        /// The call returned but the window kept its level; not retried.
        case refused
        /// This macOS does not export the calls; nothing is ever attempted.
        case unavailable
    }

    public static let aboveNormal: Int32 = 2
    private static let normal: Int32 = 0

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SetLevelFn = @convention(c) (Int32, UInt32, Int32) -> Int32

    private struct Symbols {
        let connection: ConnectionFn
        let setLevel: SetLevelFn
    }

    private var symbols: Symbols?
    private var resolved = false
    private var unavailable = false

    public init() {}

    /// Sets the level the window must have and answers whether the window
    /// server took it. Idempotent, so a caller may keep its own set of raised
    /// windows and only call this on changes.
    public func set(above: Bool, windowNumber: UInt32) -> Outcome {
        guard windowNumber != 0 else {
            return .refused
        }
        guard let symbols = resolve() else {
            return .unavailable
        }
        let level = above ? Self.aboveNormal : Self.normal
        guard symbols.setLevel(symbols.connection(), windowNumber, level) == 0 else {
            return .refused
        }
        return windowLevel(of: windowNumber) == Int(level) ? .applied : .refused
    }

    private func resolve() -> Symbols? {
        if resolved {
            return unavailable ? nil : symbols
        }
        resolved = true
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY),
              let connection = dlsym(handle, "CGSMainConnectionID"),
              let setLevel = dlsym(handle, "CGSSetWindowLevel")
        else {
            unavailable = true
            return nil
        }
        // The handle stays open for the life of the process.
        let symbols = Symbols(
            connection: unsafeBitCast(connection, to: ConnectionFn.self),
            setLevel: unsafeBitCast(setLevel, to: SetLevelFn.self)
        )
        self.symbols = symbols
        return symbols
    }

    /// The layer the window server reports for `windowNumber`, public API.
    private func windowLevel(of windowNumber: UInt32) -> Int? {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for raw in list where (raw[kCGWindowNumber as String] as? UInt32) == windowNumber {
            return raw[kCGWindowLayer as String] as? Int
        }
        return nil
    }
}
