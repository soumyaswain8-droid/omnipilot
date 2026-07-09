import XCTest
@testable import OmniPilot

final class MeetingTranscriberTests: XCTestCase {
    struct FakeWhisper: Transcribing {
        func transcribe(audioSamples: [Float]) async throws -> String {
            "chunk of \(audioSamples.count) samples"
        }
    }

    func testTickTranscribesNewWindow() async {
        let rec = MeetingRecorder(capture: AudioCapture(), sampleRate: 16_000)
        let t = MeetingTranscriber(recorder: rec, whisper: FakeWhisper(), sampleRate: 16_000)
        rec.ingest([Float](repeating: 0.1, count: 32_000))   // 2s
        await t.tick()
        let md = await t.transcriptMarkdown(recordingName: "m.wav")
        XCTAssertTrue(md.contains("**[00:00]** chunk of 32000 samples"))
        // no new audio -> no new entry
        await t.tick()
        let text = await t.transcriptText()
        XCTAssertEqual(text, "chunk of 32000 samples")
    }
}
