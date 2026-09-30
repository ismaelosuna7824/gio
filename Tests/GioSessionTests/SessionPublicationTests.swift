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
        screenRecording: Bool = true, exists: Bool = false
    ) -> SessionFactsBuilder {
        SessionFactsBuilder(context: .init(
            session: { fixture.session },
            displays: { fixture.displays.allDisplays() },
            visibleFrame: { fixture.visibleFrames[$0] },
            configMessages: { ["warning: x"] },
            engine: {
                ScrollableLayoutEngine(config: fixture.session.config.makeLayoutConfig(viewportWidth: 1800))
            },
            tileableModes: {
                Dictionary(uniqueKeysWithValues: fixture.session.registry.managedWindows().map { ($0.id, $0.mode) })
            },
            screenRecordingGranted: { screenRecording },
            accessibilityGranted: { true },
            configFileExists: { _ in exists },
            homeDirectory: { "/Users/test" },
            prefetchSnapshotContent: { prefetches.append($0) },
            log: { _, line in logs.append(line) }
        ))
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
        XCTAssertEqual(logs.count, 1)
        let snapshot = effectiveRenderer(config: fixture.session.config.animations, permission: true) == .snapshot
        XCTAssertEqual(prefetches.values, [snapshot, snapshot])
    }

    func testNoStripWithoutTheFocusedDisplay() {
        let fixture = SessionFixture(frames: [CGRect(x: 0, y: 0, width: 900, height: 1000)], focus: 0)
        fixture.displays.disconnect(SessionFixture.display)
        XCTAssertNil(make(fixture, logs: Recorder(), prefetches: Recorder()).workspaceStrip())
    }
}
