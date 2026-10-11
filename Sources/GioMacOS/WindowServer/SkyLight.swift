import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import GioCore

/// PF-L: the private SkyLight calls behind Gio's WindowServer transport,
/// resolved at runtime from the system framework (never linked), so a macOS
/// without one of them only turns the transport off. Function shapes as
/// other window managers declare them; nothing here is documented by Apple.
public struct SkyLightSymbols: @unchecked Sendable {
    typealias MainConnection = @convention(c) () -> Int32
    typealias TransactionCreate = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    typealias TransactionMove = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Void
    typealias TransactionCommit = @convention(c) (CFTypeRef, Int32) -> Void

    static let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    static let names = [
        "SLSMainConnectionID", "SLSTransactionCreate", "SLSTransactionMoveWindowWithGroup", "SLSTransactionCommit",
    ]

    let mainConnection: MainConnection
    let create: TransactionCreate
    let move: TransactionMove
    let commit: TransactionCommit

    /// Every symbol through `lookup`; the table only when none is missing.
    static func resolve(_ lookup: (String) -> UnsafeMutableRawPointer?) -> (symbols: SkyLightSymbols?, missing: [String]) {
        let pointers = names.map { lookup($0) }
        let missing = zip(names, pointers).filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty else {
            return (nil, missing)
        }
        return (
            SkyLightSymbols(
                mainConnection: unsafeBitCast(pointers[0]!, to: MainConnection.self),
                create: unsafeBitCast(pointers[1]!, to: TransactionCreate.self),
                move: unsafeBitCast(pointers[2]!, to: TransactionMove.self),
                commit: unsafeBitCast(pointers[3]!, to: TransactionCommit.self)
            ),
            []
        )
    }
}

/// PF-L: `_AXUIElementGetWindow` (HIServices, private): the `CGWindowID` of
/// an AX window element, which SkyLight moves address. Resolved once.
enum AXWindowNumber {
    typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
    static let symbol = "_AXUIElementGetWindow"

    private struct Resolved: @unchecked Sendable {
        let function: GetWindow?
    }

    private static let resolved = Resolved(
        function: dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol).map { unsafeBitCast($0, to: GetWindow.self) }
    )

    static var isAvailable: Bool { resolved.function != nil }

    /// Nil when the symbol is missing or the app did not answer.
    static func read(_ element: AXUIElement) -> UInt32? {
        guard let function = resolved.function else {
            return nil
        }
        var number: UInt32 = 0
        guard function(element, &number) == .success, number != 0 else {
            return nil
        }
        return number
    }
}

/// PF-L: SkyLight's coordinates are global with the origin at the top-left
/// of the primary display, like AX and CoreGraphics; Core speaks Cocoa. The
/// conversion happens here and nowhere else (invariant 8).
public func windowServerOrigin(of frame: CGRect, flip: AXVerticalFlip) -> CGPoint {
    flip.toAX(frame).origin
}

/// PF-L: Gio's `WindowServerMover` over SkyLight transactions: every move of
/// a batch in one transaction, committed at once (instant, atomic, without
/// the app). Window ids come from the actuator (`_AXUIElementGetWindow` at
/// registration; Gio's own windows are never registered). Called on the
/// session queue only, by `WindowReconciler`.
public final class SkyLightWindowMover: WindowServerMover, @unchecked Sendable {
    private let symbols: SkyLightSymbols
    private let windowIDs: (WindowID) -> UInt32?
    private let flip: () -> AXVerticalFlip

    init(symbols: SkyLightSymbols, windowIDs: @escaping (WindowID) -> UInt32?, flip: @escaping () -> AXVerticalFlip) {
        self.symbols = symbols
        self.windowIDs = windowIDs
        self.flip = flip
    }

    /// Opens SkyLight and resolves every symbol the transport needs
    /// (including `_AXUIElementGetWindow`). `missing` names the ones this
    /// macOS lacks; the mover exists only when none is missing.
    public static func load(
        windowIDs: @escaping (WindowID) -> UInt32?, flip: @escaping () -> AXVerticalFlip
    ) -> (mover: SkyLightWindowMover?, missing: [String]) {
        let library = dlopen(SkyLightSymbols.path, RTLD_LAZY)
        var (symbols, missing) = SkyLightSymbols.resolve { name in library.flatMap { dlsym($0, name) } }
        if !AXWindowNumber.isAvailable {
            missing.append(AXWindowNumber.symbol)
        }
        guard let symbols, missing.isEmpty else {
            return (nil, missing)
        }
        return (SkyLightWindowMover(symbols: symbols, windowIDs: windowIDs, flip: flip), [])
    }

    public func windowServerID(of id: WindowID) -> UInt32? {
        windowIDs(id)
    }

    public func commit(_ moves: [WindowServerMove]) -> Bool {
        guard !moves.isEmpty,
              let transaction = symbols.create(symbols.mainConnection())?.takeRetainedValue()
        else {
            return false
        }
        let flip = flip()
        for move in moves {
            symbols.move(transaction, move.windowID, windowServerOrigin(of: move.frame, flip: flip))
        }
        symbols.commit(transaction, 0)
        return true
    }

    /// PF-M: where the WindowServer draws `windowIDs` now, in Cocoa
    /// coordinates, for the runtime probe. Public `CGWindowListCopyWindowInfo`
    /// for each window; only the number and the bounds are read (no titles).
    public func frames(of windowIDs: [UInt32]) -> [UInt32: CGRect] {
        let height = flip().displayHeight
        var frames: [UInt32: CGRect] = [:]
        for windowID in windowIDs {
            guard let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowID))
                as? [[String: Any]],
                let entry = entries.first(where: {
                    ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
                }),
                let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else {
                continue
            }
            frames[windowID] = cocoaFrame(fromWindowServer: rect, displayHeight: height)
        }
        return frames
    }
}