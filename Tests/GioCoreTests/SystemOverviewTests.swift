import CoreGraphics
import XCTest
@testable import GioCore

/// WC-18: telling macOS's window overview (Mission Control, App Exposé) from
/// a window list, so Gio's overlays step aside while it is up.
final class SystemOverviewTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    private func surface(_ bounds: CGRect, owner: String = "WindowManager", level: Int = 19) -> OnScreenSurface {
        OnScreenSurface(owner: owner, level: level, bounds: bounds)
    }

    func testTheNormalWindowListIsNotAnOverview() {
        let surfaces = [
            surface(CGRect(x: 0, y: 0, width: 1512, height: 982), owner: "Safari", level: 0),
            surface(CGRect(x: 0, y: 0, width: 600, height: 400), owner: "Gio", level: 3),
            surface(.zero, owner: "Gio", level: -1),
        ]
        XCTAssertFalse(systemOverviewShowing(surfaces, screens: [laptop]))
    }

    func testAScreenSizedShieldIsAnOverview() {
        XCTAssertTrue(
            systemOverviewShowing([surface(laptop)], screens: [laptop]),
            "Mission Control and App Exposé both draw one"
        )
    }

    func testAShieldTheSizeOfTheSecondDisplayCounts() {
        XCTAssertTrue(systemOverviewShowing([surface(external)], screens: [laptop, external]))
    }

    func testTheSpacesBarAloneIsNotAnOverview() {
        // Mission Control is shield + Spaces bar; the bar alone is nothing.
        XCTAssertFalse(
            systemOverviewShowing([surface(CGRect(x: 500, y: 0, width: 500, height: 40), level: 14)], screens: [laptop])
        )
    }

    func testAStageManagerIconAtShieldLevelIsNotAnOverview() {
        // The 66×82 off-screen surfaces that sit at level 19 while the strip
        // is hidden, one per stage.
        XCTAssertFalse(
            systemOverviewShowing([surface(CGRect(x: -80, y: 400, width: 66, height: 82))], screens: [laptop])
        )
    }

    func testAStrayLevel19SurfaceOfAnotherAppIsIgnored() {
        XCTAssertFalse(systemOverviewShowing([surface(laptop, owner: "SomeApp")], screens: [laptop]))
    }

    func testAShieldWithoutBoundsIsNotAnOverview() {
        XCTAssertFalse(systemOverviewShowing([surface(.zero)], screens: [laptop]))
    }
}
