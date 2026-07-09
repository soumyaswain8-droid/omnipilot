import XCTest
@testable import OmniPilot

@MainActor
final class MeetingCoordinatorTests: XCTestCase {
    func testShortMeetingDiscarded() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coord-\(UUID().uuidString)")
        let coord = MeetingCoordinator.makeForTesting(archiveRoot: root, elapsed: 10)  // 10s < 60s
        coord.handle(.started(.manual))
        XCTAssertEqual(coord.state, .recording)
        await coord.handleAndWait(.ended)
        XCTAssertEqual(coord.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))  // nothing published
    }
}
