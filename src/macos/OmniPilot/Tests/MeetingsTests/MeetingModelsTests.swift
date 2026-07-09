import XCTest
@testable import OmniPilot

final class MeetingModelsTests: XCTestCase {
    func testEventEquality() {
        XCTAssertEqual(MeetingEvent.started(.manual), .started(.manual))
        XCTAssertNotEqual(MeetingEvent.started(.manual), .started(.micActive))
        XCTAssertEqual(MeetingEvent.ended, .ended)
    }

    func testTranscriptEntry() {
        let e = TranscriptEntry(startSeconds: 90, text: "hello")
        XCTAssertEqual(e.startSeconds, 90)
        XCTAssertEqual(e.text, "hello")
    }
}
