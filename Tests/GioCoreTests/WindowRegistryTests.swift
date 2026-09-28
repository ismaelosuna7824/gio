import XCTest
@testable import GioCore

final class WindowRegistryTests: XCTestCase {
    private func window(
        pid: pid_t = 100,
        element: UInt64 = 1,
        title: String = "editor",
        mode: WindowMode = .tiled
    ) -> ManagedWindow {
        ManagedWindow(
            id: WindowID(pid: pid, elementID: element),
            pid: pid,
            application: "Code",
            title: title,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            mode: mode
        )
    }

    func testRegisterAndFind() throws {
        let registry = WindowRegistry()
        let first = window()
        try registry.register(first)
        XCTAssertEqual(registry.find(first.id), first)
        XCTAssertEqual(registry.registeredCount, 1)
        XCTAssertTrue(registry.isManaged(first.id))
    }

    func testRegisterDuplicateThrows() throws {
        let registry = WindowRegistry()
        try registry.register(window())
        XCTAssertThrowsError(try registry.register(window())) { error in
            XCTAssertEqual(error as? WindowRegistryError, .duplicate(WindowID(pid: 100, elementID: 1)))
        }
    }

    func testUpdateReplacesMetadata() throws {
        let registry = WindowRegistry()
        try registry.register(window())
        var changed = window()
        changed.title = "terminal"
        changed.mode = .floating
        changed.frame = CGRect(x: 10, y: 10, width: 400, height: 300)
        try registry.update(changed)
        XCTAssertEqual(registry.find(changed.id), changed)
    }

    func testUpdateUnknownThrows() {
        let registry = WindowRegistry()
        XCTAssertThrowsError(try registry.update(window())) { error in
            XCTAssertEqual(error as? WindowRegistryError, .unknown(WindowID(pid: 100, elementID: 1)))
        }
    }

    func testRemoveReturnsRecordAndClearsIgnore() throws {
        let registry = WindowRegistry()
        let first = window()
        try registry.register(first)
        registry.ignore(first.id)
        XCTAssertEqual(registry.remove(first.id), first)
        XCTAssertNil(registry.find(first.id))
        XCTAssertFalse(registry.isIgnored(first.id))
        XCTAssertNil(registry.remove(first.id))
    }

    func testIgnoreBeforeArrivalAndUnignore() throws {
        let registry = WindowRegistry()
        let id = WindowID(pid: 7, elementID: 9)
        registry.ignore(id)
        XCTAssertTrue(registry.isIgnored(id))
        XCTAssertFalse(registry.isManaged(id))
        try registry.register(window(pid: 7, element: 9))
        XCTAssertFalse(registry.isManaged(id))
        XCTAssertTrue(registry.managedWindows().isEmpty)
        registry.unignore(id)
        XCTAssertTrue(registry.isManaged(id))
        XCTAssertEqual(registry.managedWindows().map(\.id), [id])
    }

    func testManagedWindowsAreDeterministicallyOrdered() throws {
        let registry = WindowRegistry()
        try registry.register(window(pid: 300, element: 2))
        try registry.register(window(pid: 100, element: 5))
        try registry.register(window(pid: 100, element: 1))
        XCTAssertEqual(
            registry.managedWindows().map(\.id),
            [WindowID(pid: 100, elementID: 1), WindowID(pid: 100, elementID: 5), WindowID(pid: 300, elementID: 2)]
        )
    }

    func testRemoveStaleKeepsLiveAndReturnsRemoved() throws {
        let registry = WindowRegistry()
        let live = window(pid: 100, element: 1)
        let dead = window(pid: 100, element: 2)
        try registry.register(live)
        try registry.register(dead)
        let removed = registry.removeStale(keeping: [live.id])
        XCTAssertEqual(removed, [dead])
        XCTAssertEqual(registry.find(live.id), live)
        XCTAssertNil(registry.find(dead.id))
    }

    func testRemoveStaleKeepsIgnoreMarks() throws {
        let registry = WindowRegistry()
        let id = WindowID(pid: 50, elementID: 3)
        try registry.register(window(pid: 50, element: 3))
        registry.ignore(id)
        registry.removeStale(keeping: [])
        XCTAssertTrue(registry.isIgnored(id))
        XCTAssertEqual(registry.ignoredCount, 1)
        XCTAssertEqual(registry.registeredCount, 0)
    }
}
