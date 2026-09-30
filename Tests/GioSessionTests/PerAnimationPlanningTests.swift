import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

/// NA-04: each planned flight gets the settings of its animation kind.
final class PerAnimationPlanningTests: XCTestCase {
    private func plan(_ world: ReflowWorld, cause: MotionCause, opening: Set<WindowID> = []) -> ReflowPlan {
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
                centering: .none, animating: true, duration: 0.2, opening: opening, cause: cause
            ),
            inactive: inactive, zoomTargets: { plan, _ in plan.visible }
        )
    }

    func testPlanClassifiesEntriesSwitchesAndTheRestByCause() {
        let world = ReflowWorld()
        let outgoing = world.addColumns(1)
        world.session.manager.switchTo(2)
        world.syncShown()
        let staying = world.addColumns(1, pidBase: 200)
        let new = world.addColumns(1, pidBase: 300, placed: false)[0]

        let pass = plan(world, cause: .viewScroll, opening: [new])

        XCTAssertEqual(pass.kinds[new], .windowOpen)
        XCTAssertEqual(pass.kinds[outgoing[0]], .workspaceSwitch, "drops through the bottom edge")
        XCTAssertEqual(pass.kinds[staying[0]], .horizontalViewMovement)
        XCTAssertEqual(Set(pass.kinds.keys), Set(pass.animations.map(\.id)))
    }

    func testRevealedWindowsRiseAsWorkspaceSwitch() {
        let world = ReflowWorld()
        let first = world.addColumns(1)
        world.session.manager.switchTo(2)
        world.syncShown()
        world.addColumns(1, pidBase: 200)
        _ = plan(world, cause: .workspaceSwitch)
        world.physicalFrames[first[0]] = slideDownFrame(
            CGRect(x: 0, y: 60, width: 900, height: 700), display: ReflowWorld.leftFrame
        )
        world.session.manager.switchTo(1)
        world.syncShown()

        let pass = plan(world, cause: .windowMovement)

        XCTAssertEqual(pass.kinds[first[0]], .workspaceSwitch)
    }

    // MARK: Settings per kind

    private let a = WindowID(pid: 1, elementID: 1)
    private let b = WindowID(pid: 2, elementID: 2)
    private let c = WindowID(pid: 3, elementID: 3)

    private func flights() -> [WindowAnimation] {
        [a, b, c].map {
            WindowAnimation(
                id: $0, from: CGRect(x: 0, y: 0, width: 400, height: 400),
                to: CGRect(x: 500, y: 0, width: 400, height: 400), duration: 0.2
            )
        }
    }

    func testEachFlightTakesItsKindsSpring() throws {
        var settings = AnimationsSectionConfig()
        settings.overrides[.windowOpen] = AnimationOverride(springStiffness: 300)

        let result = ReflowPlanner.applyingAnimationSettings(
            flights(), settings: settings, kinds: [a: .windowOpen], fallback: .horizontalViewMovement
        )

        XCTAssertEqual(result[0].spring?.stiffness, 300)
        XCTAssertEqual(result[1].spring?.stiffness, settings.springStiffness, "unclassified: the pass's kind")
        XCTAssertGreaterThan(result[0].duration, result[1].duration, "softer spring settles later")
    }

    func testEaseOutKindUsesItsOwnDuration() {
        var settings = AnimationsSectionConfig()
        settings.overrides[.windowMovement] = AnimationOverride(curve: .easeOut, durationMilliseconds: 90)

        let result = ReflowPlanner.applyingAnimationSettings(
            flights(), settings: settings, kinds: [b: .windowMovement], fallback: .horizontalViewMovement
        )

        XCTAssertNil(result[1].spring)
        XCTAssertEqual(result[1].duration, 0.09, accuracy: 0.0001)
        XCTAssertNotNil(result[0].spring)
    }

    func testDisabledKindJumpsOnTheNextFrameInsteadOfWaitingForTheFinalPass() {
        var settings = AnimationsSectionConfig()
        settings.overrides[.workspaceSwitch] = AnimationOverride(enabled: false)
        var flight = flights()
        flight[2].sizeSchedule = .atStart

        let result = ReflowPlanner.applyingAnimationSettings(
            flight, settings: settings, kinds: [c: .workspaceSwitch], fallback: .windowMovement
        )

        XCTAssertNil(result[2].spring)
        XCTAssertEqual(result[2].easing, .linear)
        XCTAssertLessThanOrEqual(result[2].duration, 0.001)
        XCTAssertEqual(result[2].to, flight[2].to)
        XCTAssertEqual(result[2].sizeSchedule, .atStart)
        XCTAssertEqual(result[2].frame(at: 0.001), flight[2].to)
    }

    func testWithoutOverridesMatchesTheGlobalCurve() {
        for curve in [MotionCurveKind.spring, .easeOut] {
            var settings = AnimationsSectionConfig()
            settings.curve = curve
            XCTAssertEqual(
                ReflowPlanner.applyingAnimationSettings(
                    flights(), settings: settings, kinds: [a: .windowOpen, b: .windowClose], fallback: .windowResize
                ),
                ReflowPlanner.applyingCurve(flights(), settings: settings)
            )
        }
    }
}
