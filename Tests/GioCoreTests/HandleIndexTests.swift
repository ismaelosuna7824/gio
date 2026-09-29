import XCTest
@testable import GioCore

/// PA-04: retained AX handles are found by element hash bucket, verified
/// with the real equality inside the bucket.
final class HandleIndexTests: XCTestCase {
    /// `hash` collides on the first letter, so "apple" and "avocado" share a bucket.
    private func makeIndex() -> HandleIndex<String> {
        HandleIndex(hash: { $0.unicodeScalars.first.map { Int($0.value) } ?? 0 }, equal: { $0 == $1 })
    }

    func testFindsARegisteredElement() {
        var index = makeIndex()
        index.insert(elementID: 1, pid: 10, element: "apple")
        XCTAssertEqual(index.find("apple", pid: 10), 1)
    }

    func testUnknownElementIsNil() {
        var index = makeIndex()
        index.insert(elementID: 1, pid: 10, element: "apple")
        XCTAssertNil(index.find("banana", pid: 10))
    }

    func testCollidingElementsAreToldApartByEquality() {
        var index = makeIndex()
        index.insert(elementID: 1, pid: 10, element: "apple")
        index.insert(elementID: 2, pid: 10, element: "avocado")
        XCTAssertEqual(index.find("apple", pid: 10), 1)
        XCTAssertEqual(index.find("avocado", pid: 10), 2)
        XCTAssertNil(index.find("apricot", pid: 10))
    }

    func testPidMustMatchWithinABucket() {
        var index = makeIndex()
        index.insert(elementID: 1, pid: 10, element: "apple")
        XCTAssertNil(index.find("apple", pid: 11))
    }

    func testRemoveKeepsTheCollidingNeighbour() {
        var index = makeIndex()
        index.insert(elementID: 1, pid: 10, element: "apple")
        index.insert(elementID: 2, pid: 10, element: "avocado")
        index.remove(elementID: 1)
        XCTAssertNil(index.find("apple", pid: 10))
        XCTAssertEqual(index.find("avocado", pid: 10), 2)
    }

    func testRemovingTheLastEntryEmptiesTheBucket() {
        var index = makeIndex()
        index.insert(elementID: 1, pid: 10, element: "apple")
        index.remove(elementID: 1)
        XCTAssertNil(index.find("apple", pid: 10))
        XCTAssertEqual(index.count, 0)
    }

    func testReinsertingAnIDReplacesItsElement() {
        var index = makeIndex()
        index.insert(elementID: 1, pid: 10, element: "apple")
        index.insert(elementID: 1, pid: 10, element: "avocado")
        XCTAssertNil(index.find("apple", pid: 10))
        XCTAssertEqual(index.find("avocado", pid: 10), 1)
        XCTAssertEqual(index.count, 1)
    }

    func testRemovingAnUnknownIDIsANoop() {
        var index = makeIndex()
        index.remove(elementID: 9)
        XCTAssertEqual(index.count, 0)
    }
}
