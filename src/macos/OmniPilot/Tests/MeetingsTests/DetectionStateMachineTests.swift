import XCTest
@testable import OmniPilot

final class DetectionStateMachineTests: XCTestCase {
    func make() -> DetectionStateMachine {
        DetectionStateMachine(startHold: 5, endDebounce: 15, minMeeting: 60,
                              knownMeetingApps: ["us.zoom.xos"])
    }

    func testMicActiveHeldStartsMeeting() {
        var m = make()
        XCTAssertNil(m.update(.micActive(true), now: 0))
        XCTAssertNil(m.update(.tick, now: 4))              // not held long enough
        XCTAssertEqual(m.update(.tick, now: 5), .started(.micActive))  // 5s held
        XCTAssertNil(m.update(.tick, now: 6))              // no duplicate start
    }

    func testMuteDoesNotEnd() {
        var m = make()
        _ = m.update(.micActive(true), now: 0)
        _ = m.update(.tick, now: 5)                        // started
        // mic stays active (mute keeps device running) for a long time
        XCTAssertNil(m.update(.tick, now: 600))
    }

    func testMicReleasedEndsAfterDebounce() {
        var m = make()
        _ = m.update(.micActive(true), now: 0)
        _ = m.update(.tick, now: 5)                        // started
        XCTAssertNil(m.update(.micActive(false), now: 100))
        XCTAssertNil(m.update(.tick, now: 110))            // 10s < 15s debounce
        XCTAssertEqual(m.update(.tick, now: 115), .ended)  // 15s released
    }

    func testMicBlipDoesNotEnd() {
        var m = make()
        _ = m.update(.micActive(true), now: 0); _ = m.update(.tick, now: 5)
        _ = m.update(.micActive(false), now: 100)
        _ = m.update(.micActive(true), now: 105)           // came back before debounce
        XCTAssertNil(m.update(.tick, now: 200))            // still running, no end
    }

    func testKnownAppQuitEnds() {
        var m = make()
        _ = m.update(.micActive(true), now: 0); _ = m.update(.tick, now: 5)
        XCTAssertEqual(m.update(.appTerminated("us.zoom.xos"), now: 50), .ended)
    }

    func testManualStartStop() {
        var m = make()
        XCTAssertEqual(m.update(.manualStart, now: 0), .started(.manual))
        XCTAssertEqual(m.update(.manualStop, now: 3), .ended)
    }
}
