import XCTest
@testable import GioSession

final class GioSessionModuleTests: XCTestCase {
    func testModuleIsLinkedAndNamed() {
        XCTAssertEqual(GioSessionModule.name, "GioSession")
    }
}
