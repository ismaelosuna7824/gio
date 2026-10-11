import XCTest
@testable import GioCore
@testable import GioMacOS

/// TG-03: the MultitouchSupport adapter resolves its private symbols at
/// runtime and reports the missing ones (gestures then stay off), and copies
/// contact frames out of the framework's memory into plain values.
final class MultitouchTests: XCTestCase {
    private let dummy = UnsafeMutableRawPointer(bitPattern: 0x1000)!

    func testEveryMissingSymbolIsNamedAndNothingIsBuilt() {
        let present: Set<String> = ["MTDeviceCreateList", "MTDeviceStop"]
        let resolved = MultitouchSymbols.resolve { present.contains($0) ? self.dummy : nil }
        XCTAssertNil(resolved.symbols)
        XCTAssertEqual(resolved.missing, [
            "MTDeviceStart", "MTRegisterContactFrameCallbackWithRefcon", "MTUnregisterContactFrameCallback",
        ])
    }

    func testAllSymbolsPresentBuildTheTable() {
        let resolved = MultitouchSymbols.resolve { _ in self.dummy }
        XCTAssertNotNil(resolved.symbols)
        XCTAssertEqual(resolved.missing, [])
    }

    /// Resolving only looks the symbols up: no device is opened or started.
    func testLoadingReportsASourceOnlyWithoutMissingSymbols() {
        let loaded = MultitouchSource.load { _ in }
        XCTAssertEqual(loaded.source == nil, !loaded.missing.isEmpty)
    }

    func testContactFramesKeepOnlyFingersOnTheSurface() {
        let stride = MultitouchLayout.stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: stride * 3, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: stride * 3)
        func touch(_ index: Int, id: Int32, state: Int32, x: Float, y: Float) {
            let base = buffer + index * stride
            base.storeBytes(of: id, toByteOffset: MultitouchLayout.identifier, as: Int32.self)
            base.storeBytes(of: state, toByteOffset: MultitouchLayout.state, as: Int32.self)
            base.storeBytes(of: x, toByteOffset: MultitouchLayout.x, as: Float.self)
            base.storeBytes(of: y, toByteOffset: MultitouchLayout.y, as: Float.self)
        }
        touch(0, id: 7, state: 4, x: 0.25, y: 0.5)
        touch(1, id: 8, state: 3, x: 0.75, y: 0.25)
        touch(2, id: 9, state: 7, x: 0.5, y: 0.5)

        let frame = touchFrame(contacts: buffer, count: 3, timestamp: 12.5)
        XCTAssertEqual(frame, TouchFrame(timestamp: 12.5, contacts: [
            TouchContact(id: 7, x: 0.25, y: 0.5), TouchContact(id: 8, x: 0.75, y: 0.25),
        ]))
        XCTAssertEqual(touchFrame(contacts: nil, count: 2, timestamp: 1), TouchFrame(timestamp: 1, contacts: []))
    }
}
