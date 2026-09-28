import ApplicationServices
import XCTest
@testable import GioMac

final class SpaceWindowSnapshotTests: XCTestCase {
    private func row(id: Int = 1, pid: Int = 42, title: String? = "Editor") -> [String: Any] {
        var result: [String: Any] = [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
            kCGWindowBounds as String: ["X": 10, "Y": 20, "Width": 300, "Height": 200]]
        if let title { result[kCGWindowName as String] = title }
        return result
    }

    private func assemble(_ rows: [[String: Any]], regularPIDs: Set<pid_t> = [42],
                          epoch: @escaping () -> UInt64 = { 7 },
                          second: [[String: Any]]? = nil,
                          enumerate: (pid_t) throws -> [SpaceWindowSnapshot.Window]) throws -> SpaceWindowSnapshot {
        var reads = 0
        return try SpaceWindowSnapshot.assemble(generation: 7, currentGeneration: epoch,
            readCG: {
                reads += 1
                return reads == 1 ? rows : (second ?? rows)
            }, regularPIDs: regularPIDs, enumerate: enumerate)
    }

    func testPublicMetadataParsingPreservesDuplicatesAndMissingFields() {
        let parsed = SpaceCGMetadata.parse([row(), row(), row(title: nil),
                                            [kCGWindowOwnerPID as String: 0]])
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].frame, CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertNil(parsed[2].title)
        XCTAssertEqual(parsed[0].pid, parsed[1].pid)
    }

    func testEmptyCGSkipsAXWithoutPromptOrRuntimeAccess() throws {
        let snapshot = try assemble([]) { _ in
            XCTFail("No on-screen PID should be enumerated")
            return []
        }
        XCTAssertEqual(snapshot.generation, 7)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertTrue(snapshot.onScreen.isEmpty)
    }

    func testIncompletePIDEnumerationDiscardsAllResults() {
        XCTAssertThrowsError(try assemble([row(pid: 42), row(id: 2, pid: 43)], regularPIDs: [42, 43]) { pid in
            if pid == 43 { throw SpaceWindowSnapshotError.incompletePID(pid) }
            return []
        }) { error in
            XCTAssertEqual(error as? SpaceWindowSnapshotError, .incompletePID(43))
        }
    }

    func testNonRegularPIDNeverEnumerated() throws {
        let snapshot = try assemble([row()], regularPIDs: []) { _ in
            XCTFail("Nonregular process")
            return []
        }
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.onScreen.count, 1)
    }

    func testEpochChangedBeforeFirstReadOrDuringEnumerationFailsClosed() {
        var reads = 0
        XCTAssertThrowsError(try assemble([row()], epoch: { 8 }) { _ in
            XCTFail("Stale epoch must not enumerate")
            return []
        }) { XCTAssertEqual($0 as? SpaceWindowSnapshotError, .staleSnapshot) }
        XCTAssertThrowsError(try assemble([row()], epoch: { reads += 1; return reads == 1 ? 7 : 8 }, enumerate: { _ in [] })) {
            XCTAssertEqual($0 as? SpaceWindowSnapshotError, .staleSnapshot)
        }
    }

    func testIncompleteRelevantCGMetadataFailsBeforeAXAndIrrelevantRowsDoNotBlock() throws {
        let incomplete: [[[String: Any]]] = [[row(), row()], [row(title: nil)],
            [[kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: 2]],
            [row(id: 0)]]
        for rows in incomplete {
            XCTAssertThrowsError(try assemble(rows) { _ in
                XCTFail("Incomplete CG metadata must not enumerate AX")
                return []
            }) { XCTAssertEqual($0 as? SpaceWindowSnapshotError, .incompleteCGMetadata) }
        }
        let irrelevant: [[String: Any]] = [[kCGWindowOwnerPID as String: 99],
                                          [kCGWindowOwnerPID as String: 99, kCGWindowNumber as String: 1]]
        let snapshot = try assemble([row()] + irrelevant) { _ in [] }
        XCTAssertEqual(snapshot.onScreen.count, 3)
    }

    func testCGFingerprintChangeFailsClosedButReorderingDoesNot() throws {
        let original = [row(), row(id: 2, title: "Second")]
        for changed in [[row(id: 3), original[1]], [row(title: "Changed"), original[1]],
                        [row()]] {
            XCTAssertThrowsError(try assemble(original, second: changed, enumerate: { _ in [] })) {
                XCTAssertEqual($0 as? SpaceWindowSnapshotError, .staleSnapshot)
            }
        }
        XCTAssertThrowsError(try assemble(original, second: [row(), row()], enumerate: { _ in [] })) {
            XCTAssertEqual($0 as? SpaceWindowSnapshotError, .incompleteCGMetadata)
        }
        let stable = try assemble(original, second: Array(original.reversed()), enumerate: { _ in [] })
        XCTAssertEqual(stable.onScreen.count, 2)
        XCTAssertEqual(stable.onScreen[1].title, "Second")
    }
}
