import XCTest
@testable import OmniPilot

final class MeetingRecorderTests: XCTestCase {
    func testWindowingTracksOffset() {
        let rec = MeetingRecorder(capture: AudioCapture(), sampleRate: 16_000)
        rec.ingest([Float](repeating: 0.1, count: 16_000))   // 1s
        rec.ingest([Float](repeating: 0.2, count: 16_000))   // 1s
        XCTAssertEqual(rec.totalSamples, 32_000)
        let w1 = rec.windowSince(0)
        XCTAssertEqual(w1.samples.count, 32_000)
        XCTAssertEqual(w1.newOffset, 32_000)
        rec.ingest([Float](repeating: 0.3, count: 8_000))
        let w2 = rec.windowSince(w1.newOffset)
        XCTAssertEqual(w2.samples.count, 8_000)
        XCTAssertEqual(w2.newOffset, 40_000)
    }
}
