import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

/// NA-02: a newly opened window enters from just below its tile while its
/// neighbours slide to make room.
final class WindowOpenPlanningTests: XCTestCase {
    private func plan(
        _ world: ReflowWorld, opening: Set<WindowID>, animating: Bool = true, offset: CGFloat = 24
    ) -> ReflowPlan {
        let planner = ReflowPlanner(context: .init(
            physicalFrames: { world.physicalFrames },
            readFrame: { world.read($0) },
            storePhysicalFrame: { world.physicalFrames[$0] = $1 }
        ))
        let inactive = planner.planInactiveWorkspaces(
            displays: world.displays.allDisplays(), manager: world.session.manager, registry: world.session.registry
        )
        return planner.plan(
            .init(
                displays: world.displays.allDisplays(), visibleFrames: world.visibleFrames,
                manager: world.session.manager, modes: world.modes, engine: { world.engine() },
                centering: .none, animating: animating, duration: 0.2,
                opening: opening, openOffset: offset
            ),
            inactive: inactive, zoomTargets: { plan, _ in plan.visible }
        )
    }

    func testNewWindowIsPrepositionedBelowItsTileAndRisesIntoIt() throws {
        let world = ReflowWorld()
        let neighbours = world.addColumns(1)
        let new = world.addColumns(1, pidBase: 200, placed: false)[0]

        let pass = plan(world, opening: [new])

        let target = try XCTUnwrap(pass.plans[0].visible[new])
        let start = CGRect(x: target.minX, y: target.minY - 24, width: target.width, height: target.height)
        XCTAssertEqual(pass.prepositions[new], start, "one write: final size, origin 24 pt lower")
        let entry = try XCTUnwrap(pass.animations.first { $0.id == new })
        XCTAssertEqual(entry.from, start)
        XCTAssertEqual(entry.to, target)
        XCTAssertEqual(world.reads, [new], "the app's frame is read once, for the pre-position write")
        let neighbour = try XCTUnwrap(pass.animations.first { $0.id == neighbours[0] })
        XCTAssertNotEqual(neighbour.from, neighbour.to, "the neighbour slides to make room")
    }

    func testWindowsThatDidNotJustOpenFlyAsBefore() {
        let world = ReflowWorld()
        world.addColumns(1)
        let new = world.addColumns(1, pidBase: 200, placed: false)[0]

        let pass = plan(world, opening: [])

        XCTAssertNil(pass.prepositions[new])
        XCTAssertEqual(pass.animations.first { $0.id == new }?.from, world.readable[new])
    }

    func testNewWindowInAParkedColumnIsNotAnimatedIn() {
        let world = ReflowWorld()
        let new = world.addColumns(1, pidBase: 200, placed: false)[0]
        world.addColumns(4)

        let pass = plan(world, opening: [new])

        XCTAssertNotNil(pass.plans[0].parked[new], "fixture: the new column is off the viewport")
        XCTAssertNil(pass.prepositions[new])
    }

    func testNewWindowOnAHiddenWorkspaceIsNotAnimatedIn() {
        let world = ReflowWorld()
        world.addColumns(1)
        let new = world.addColumns(1, pidBase: 200, placed: false)[0]
        world.session.manager.moveWindow(new, to: 2)

        let pass = plan(world, opening: [new])

        XCTAssertNil(pass.prepositions[new])
        XCTAssertFalse(pass.animations.contains { $0.id == new && $0.to.minY > 0 })
    }

    func testInstantPassPlacesTheNewWindowWithoutEntry() {
        let world = ReflowWorld()
        let new = world.addColumns(1, pidBase: 200, placed: false)[0]

        let pass = plan(world, opening: [new], animating: false)

        XCTAssertTrue(pass.prepositions.isEmpty)
        XCTAssertTrue(pass.animations.isEmpty)
    }

    func testUnreadableNewWindowIsNotPrepositioned() {
        let world = ReflowWorld()
        let new = world.addColumns(1, pidBase: 200, placed: false)[0]
        world.readable = [:]

        let pass = plan(world, opening: [new])

        XCTAssertNil(pass.prepositions[new], "no known frame to write from")
    }

    func testZeroOffsetWritesTheTileDirectlyWithoutFlight() throws {
        let world = ReflowWorld()
        let new = world.addColumns(1, pidBase: 200, placed: false)[0]

        let pass = plan(world, opening: [new], offset: 0)

        XCTAssertEqual(pass.prepositions[new], try XCTUnwrap(pass.plans[0].visible[new]))
        XCTAssertFalse(pass.animations.contains { $0.id == new })
    }

    // MARK: Close (NA-03)

    func testNeighboursGlideIntoTheGapOfAClosedWindow() throws {
        let world = ReflowWorld()
        let ids = world.addColumns(3)
        _ = plan(world, opening: [])
        var workspace = world.session.manager.currentWorkspace()
        workspace.stripWindows([ids[0]])
        world.session.manager.update(workspace)
        world.physicalFrames.removeValue(forKey: ids[0])

        let pass = plan(world, opening: [])

        let glide = try XCTUnwrap(pass.animations.first { $0.id == ids[1] })
        XCTAssertLessThan(glide.to.minX, glide.from.minX, "the right neighbour moves left into the gap")
        XCTAssertFalse(pass.animations.contains { $0.id == ids[0] })
    }
}
