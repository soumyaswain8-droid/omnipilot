import XCTest
@testable import OmniPilot

final class TranscriptBuilderTests: XCTestCase {
    func testAppendAndMarkdown() {
        var b = TranscriptBuilder()
        b.append(startSeconds: 0, rawText: "  Hello everyone  ")
        b.append(startSeconds: 90, rawText: "second window")
        let md = b.markdown(recordingName: "mtg.wav")
        XCTAssertTrue(md.contains("# Meeting Transcript"))
        XCTAssertTrue(md.contains("`mtg.wav`"))
        XCTAssertTrue(md.contains("**[00:00]** Hello everyone"))
        XCTAssertTrue(md.contains("**[01:30]** second window"))
    }

    func testEmptyAndWhitespaceSkipped() {
        var b = TranscriptBuilder()
        b.append(startSeconds: 0, rawText: "   ")
        XCTAssertTrue(b.isEmpty)
    }

    func testPlainTextHasNoTimestamps() {
        var b = TranscriptBuilder()
        b.append(startSeconds: 65, rawText: "content here")
        XCTAssertEqual(b.plainText().trimmingCharacters(in: .whitespacesAndNewlines), "content here")
    }
}
