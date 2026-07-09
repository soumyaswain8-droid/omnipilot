import XCTest
@testable import OmniPilot

final class MeetingSummarizerTests: XCTestCase {
    struct FakeLLM: LLMGenerating {
        let map: String; let reduce: String
        func generate(prompt: String, system: String?) async throws -> String {
            prompt.contains("FINAL notes") ? reduce : map
        }
    }

    func testChunking() {
        let text = String(repeating: "a", count: 25_000)
        let chunks = MeetingSummarizer.chunks(text, size: 12_000)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.joined().count, 25_000)
    }

    func testNormalizeMishears() {
        let n = MeetingSummarizer.normalizeMishears("Open Nurbukkalem and Nurbukh alum today")
        XCTAssertFalse(n.contains("Nurbukkalem"))
        XCTAssertTrue(n.contains("NotebookLM"))
    }

    func testMapReduceProducesReducedOutput() async throws {
        let s = MeetingSummarizer(llm: FakeLLM(map: "- point", reduce: "# Notes\nTL;DR ok"))
        let out = try await s.summarize(transcript: String(repeating: "word ", count: 5000))
        XCTAssertTrue(out.contains("TL;DR ok"))
    }
}
