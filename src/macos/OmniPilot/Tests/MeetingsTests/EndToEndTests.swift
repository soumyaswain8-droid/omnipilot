import XCTest
@testable import OmniPilot

final class EndToEndTests: XCTestCase {
    struct StubWhisper: Transcribing {
        func transcribe(audioSamples: [Float]) async throws -> String { "we discussed the roadmap and next steps" }
    }
    struct StubLLM: LLMGenerating {
        func generate(prompt: String, system: String?) async throws -> String {
            prompt.contains("FINAL notes") ? "## TL;DR\nRoadmap discussed.\n## Action Items\n- [ ] follow up" : "- roadmap"
        }
    }

    func testFullPipelineProducesArtifacts() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("e2e-\(UUID().uuidString)")

        // 1. record: feed 3 windows of 90s of silence-sized buffers via ingest
        let rec = MeetingRecorder(capture: AudioCapture(), sampleRate: 16_000)
        let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("e2e.m4a")
        try rec.start(writingTo: audioURL)
        for _ in 0..<3 { rec.ingest([Float](repeating: 0.05, count: 16_000 * 90)) }
        // 2. transcribe
        let t = MeetingTranscriber(recorder: rec, whisper: StubWhisper(), sampleRate: 16_000)
        await t.tick(); await t.flush()
        _ = rec.stop()
        // 3. summarize
        let transcriptText = await t.transcriptText()
        let transcriptMD = await t.transcriptMarkdown(recordingName: "audio.m4a")
        let notes = try await MeetingSummarizer(llm: StubLLM()).summarize(transcript: transcriptText)
        // 4. publish
        let art = try ArchivePublisher(layout: ArchiveLayout(root: root))
            .publish(date: Date(), title: "Roadmap", notes: notes,
                     transcript: transcriptMD, audio: audioURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: art.notesMD.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: art.transcriptMD.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: art.audioM4A.path))
        let notesText = try String(contentsOf: art.notesMD, encoding: .utf8)
        XCTAssertTrue(notesText.contains("TL;DR"))
        XCTAssertTrue(notesText.contains("Action Items"))
    }
}
