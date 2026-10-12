import CoreGraphics
import GioCore
import XCTest
@testable import GioSession

/// Same contract as the menu bar's `BarStateGate`: drops repeats, nil included.
private struct DedupeGate: PublicationGate {
    private var last: String??

    mutating func accept(_ value: String?) -> Bool {
        if let last, last == value {
            return false
        }
        last = .some(value)
        return true
    }
}

final class GatedStatePublisherTests: XCTestCase {
    private final class Source: @unchecked Sendable {
        var observed = true
        var value: String?
        var builds = 0
    }

    private func make(_ source: Source, hop: HopRecorder, delivered: Recorder<String?>)
        -> GatedStatePublisher<DedupeGate>
    {
        GatedStatePublisher(gate: DedupeGate(), initial: nil, context: .init(
            isObserved: { source.observed },
            makeValue: {
                source.builds += 1
                return source.value
            },
            mainHop: hop.hop,
            deliver: { delivered.append($0) }
        ))
    }

    func testPublishesChangesOnceAndReadsWithoutWaiting() {
        let source = Source()
        let hop = HopRecorder()
        let delivered = Recorder<String?>()
        let publisher = make(source, hop: hop, delivered: delivered)
        publisher.publish()
        source.value = "a"
        publisher.publish()
        publisher.publish()
        XCTAssertEqual(publisher.read(), "a", "cell updates before the main hop")
        hop.drain()
        XCTAssertEqual(delivered.values, [nil, "a"])
    }

    func testUnobservedPublisherBuildsNothing() {
        let source = Source()
        source.observed = false
        let hop = HopRecorder()
        let delivered = Recorder<String?>()
        let publisher = make(source, hop: hop, delivered: delivered)
        publisher.publish()
        XCTAssertEqual(source.builds, 0)
        source.observed = true
        publisher.publish()
        hop.drain()
        XCTAssertEqual(delivered.values, [nil])
    }
}

final class SessionFactsBuilderTests: XCTestCase {
    private func make(
        _ fixture: SessionFixture, logs: Recorder<String>, prefetches: Recorder<Bool>,
        screenRecording: Bool = true, exists: Bool = false,
        windowServer: WindowServerTransportStatus = windowServerTransportStatus(enabled: true, missingSymbols: []),
        gestures: GestureSourceStatus = gestureSourceStatus(enabled: true, missingSymbols: [], devices: 1),
        conflicts: [GestureConflict] = []
    ) -> SessionFactsBuilder {
        SessionFactsBuilder(context: .init(
            session: { fixture.session },
            displays: { fixture.displays.allDisplays() },
            visibleFrame: { fixture.visibleFrames[$0] },
            configMessages: { ["warning: x"] },
            engine: {
                ScrollableLayoutEngine(config: fixture.session.config.makeLayoutConfig())
            },
            tileableModes: {
                Dictionary(uniqueKeysWithValues: fixture.session.registry.managedWindows().map { ($0.id, $0.mode) })
            },
            screenRecordingGranted: { screenRecording },
            accessibilityGranted: { true },
            configFileExists: { _ in exists },
            homeDirectory: { "/Users/test" },
            prefetchSnapshotContent: { prefetches.append($0) },
            windowServerStatus: { windowServer },
            gestureStatus: { gestures },
            gestureConflicts: { conflicts },
            log: { _, line in logs.append(line) }
        ))
    }

    /// TG-04: collisions with macOS's own swipes are logged once (again on
    /// change, without titles) and published for Diagnostics and Settings.
    func testGestureConflictsAreLoggedOnceAndPublished() {
        let fixture = SessionFixture(frames: [CGRect(x: 0, y: 0, width: 900, height: 1000)], focus: 0)
        let logs = Recorder<String>()
        let conflicts = [GestureConflict(gesture: .scroll, fingers: 3, system: .fullScreenSwipe)]
        let builder = make(fixture, logs: logs, prefetches: Recorder(), conflicts: conflicts)
        let facts = builder.facts()
        _ = builder.facts()
        XCTAssertEqual(facts.gestureConflicts, conflicts)
        XCTAssertEqual(
            logs.values.filter { $0.hasPrefix("gestures conflict") }, ["gestures conflict=scroll-3:full-screen-swipe"]
        )
    }

    func testBuildsWindowFactsWithWorkspaceAndVisibility() {
        let fixture = SessionFixture(frames: [CGRect(x: 0, y: 0, width: 900, height: 1000)], focus: 0)
        let facts = make(fixture, logs: Recorder(), prefetches: Recorder()).facts()
        XCTAssertEqual(facts.configPath, "/Users/test/.config/gio/config.toml")
        XCTAssertFalse(facts.configExists)
        XCTAssertEqual(facts.configMessages, ["warning: x"])
        XCTAssertTrue(facts.accessibilityGranted)
        XCTAssertTrue(facts.screenRecordingGranted)
        XCTAssertEqual(facts.currentWorkspace, fixture.session.manager.current)
        XCTAssertEqual(facts.windows.map(\.id), ["1:1"])
        XCTAssertEqual(facts.windows.first?.workspace, 1)
        XCTAssertEqual(facts.windows.first?.workspaceIsShown, true)
        XCTAssertEqual(facts.displays.map(\.id), [1])
        XCTAssertNotNil(facts.strip)
    }

    func testConfiguredPathWinsOverTheDefault() {
        let fixture = SessionFixture()
        fixture.session.configPath = "/tmp/gio-test.toml"
        let facts = make(fixture, logs: Recorder(), prefetches: Recorder(), exists: true).facts()
        XCTAssertEqual(facts.configPath, "/tmp/gio-test.toml")
        XCTAssertTrue(facts.configExists)
    }

    func testRendererLineIsLoggedOnceAndPrefetchFollowsTheRenderer() {
        let fixture = SessionFixture(frames: [CGRect(x: 0, y: 0, width: 900, height: 1000)], focus: 0)
        let logs = Recorder<String>()
        let prefetches = Recorder<Bool>()
        let builder = make(fixture, logs: logs, prefetches: prefetches)
        _ = builder.facts()
        _ = builder.facts()
        XCTAssertEqual(logs.values.filter { $0.hasPrefix("renderer ") }.count, 1)
        let snapshot = effectiveRenderer(
            config: fixture.session.config.animations, permission: true, windowServer: true
        ) == .snapshot
        XCTAssertEqual(prefetches.values, [snapshot, snapshot])
    }

    /// PF-O: the default live renderer needs SkyLight. Without it (config
    /// off, missing symbols, a failed probe) the log says the motion falls
    /// back to the AX renderer, once per change, and the snapshot content is
    /// not prefetched; with it the line names `live`.
    func testLiveFallsBackToAXWithoutSkyLightAndSaysWhy() {
        let fixture = SessionFixture(frames: [CGRect(x: 0, y: 0, width: 900, height: 1000)], focus: 0)
        XCTAssertEqual(fixture.session.config.animations.renderer, .live)
        let failed = windowServerTransportStatus(enabled: true, missingSymbols: [], probe: .failed)
        let logs = Recorder<String>()
        let prefetches = Recorder<Bool>()
        let builder = make(fixture, logs: logs, prefetches: prefetches, windowServer: failed)
        _ = builder.facts()
        _ = builder.facts()
        XCTAssertEqual(
            logs.values.filter { $0.hasPrefix("renderer ") }, ["renderer effective=ax reason=skylight-unavailable"]
        )
        XCTAssertEqual(prefetches.values, [false, false])

        let liveLogs = Recorder<String>()
        _ = make(fixture, logs: liveLogs, prefetches: Recorder()).facts()
        XCTAssertEqual(liveLogs.values.filter { $0.hasPrefix("renderer ") }, ["renderer effective=live reason=configured"])
    }

    /// PF-L: the WindowServer transport state is logged once (again only
    /// when it changes) and published for Diagnostics.
    func testSkyLightStatusIsLoggedOnceAndPublished() {
        let fixture = SessionFixture(frames: [CGRect(x: 0, y: 0, width: 900, height: 1000)], focus: 0)
        let logs = Recorder<String>()
        let off = windowServerTransportStatus(enabled: false, missingSymbols: [])
        let builder = make(fixture, logs: logs, prefetches: Recorder(), windowServer: off)
        let facts = builder.facts()
        _ = builder.facts()
        XCTAssertEqual(facts.windowServer, off)
        XCTAssertEqual(logs.values.filter { $0.hasPrefix("skylight ") }, ["skylight available=false reason=config-off"])
    }

    /// TG-03: whether trackpad gestures run is logged once (again only when
    /// it changes) and published for Diagnostics.
    func testGestureStatusIsLoggedOnceAndPublished() {
        let fixture = SessionFixture(frames: [CGRect(x: 0, y: 0, width: 900, height: 1000)], focus: 0)
        let logs = Recorder<String>()
        let missing = gestureSourceStatus(enabled: true, missingSymbols: ["MTDeviceStart"], devices: 0)
        let builder = make(fixture, logs: logs, prefetches: Recorder(), gestures: missing)
        let facts = builder.facts()
        _ = builder.facts()
        XCTAssertEqual(facts.gestures, missing)
        XCTAssertEqual(
            logs.values.filter { $0.hasPrefix("gestures available") }, ["gestures available=false reason=missing-symbols:MTDeviceStart"]
        )
    }

    func testNoStripWithoutTheFocusedDisplay() {
        let fixture = SessionFixture(frames: [CGRect(x: 0, y: 0, width: 900, height: 1000)], focus: 0)
        fixture.displays.disconnect(SessionFixture.display)
        XCTAssertNil(make(fixture, logs: Recorder(), prefetches: Recorder()).workspaceStrip())
    }

    func testOverviewLaysOutEveryWorkspaceOfTheFocusedDisplay() {
        let fixture = SessionFixture(
            frames: [CGRect(x: 0, y: 0, width: 900, height: 1000), CGRect(x: 900, y: 0, width: 900, height: 1000)],
            focus: 0
        )
        XCTAssertTrue(fixture.session.manager.moveWindow(SessionFixture.id(1, pid: 2), to: 2))
        let overview = make(fixture, logs: Recorder(), prefetches: Recorder()).workspaceOverview()
        XCTAssertEqual(overview?.displayID, 1)
        XCTAssertEqual(overview?.activeWorkspace, 1)
        XCTAssertEqual(overview?.strips.map(\.workspace), [1, 2, 3])
        XCTAssertEqual(overview?.strips.map(overviewWindowOrder), [["1:1"], ["2:2"], []])
        XCTAssertEqual(overview?.strips.first?.focusedWindowID, "1:1")
    }

    func testNoOverviewWithoutTheFocusedDisplay() {
        let fixture = SessionFixture(frames: [CGRect(x: 0, y: 0, width: 900, height: 1000)], focus: 0)
        fixture.displays.disconnect(SessionFixture.display)
        XCTAssertNil(make(fixture, logs: Recorder(), prefetches: Recorder()).workspaceOverview())
    }
}
