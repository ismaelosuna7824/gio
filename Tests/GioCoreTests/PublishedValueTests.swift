import XCTest
@testable import GioCore

final class PublishedValueTests: XCTestCase {
    func testReadReturnsInitialThenLatestPublish() {
        let cell = PublishedValue(1)
        XCTAssertEqual(cell.read(), 1)
        cell.publish(2)
        cell.publish(3)
        XCTAssertEqual(cell.read(), 3)
    }

    func testReadNeverBlocksOnAPublisherThread() {
        let cell = PublishedValue(0)
        let group = DispatchGroup()
        for value in 1...200 {
            DispatchQueue.global().async(group: group) { cell.publish(value) }
            _ = cell.read()
        }
        group.wait()
        XCTAssertTrue((1...200).contains(cell.read()))
    }
}
