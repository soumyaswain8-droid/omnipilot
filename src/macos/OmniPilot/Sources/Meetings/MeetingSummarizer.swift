import Foundation

/// Abstraction over the LLM so the summarizer is testable without Ollama.
protocol LLMGenerating {
    func generate(prompt: String, system: String?) async throws -> String
}

extension OllamaClient: LLMGenerating {}

/// Map-reduce summarizer: chunk transcript → per-chunk bullets → combined structured notes.
struct MeetingSummarizer {
    let llm: LLMGenerating
    init(llm: LLMGenerating) { self.llm = llm }

    static func chunks(_ text: String, size: Int = 12_000) -> [String] {
        guard size > 0, !text.isEmpty else { return text.isEmpty ? [] : [text] }
        var out: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[idx..<end]))
            idx = end
        }
        return out
    }

    /// Deterministic fixes for known whisper mishears (summarizer copy only).
    static func normalizeMishears(_ text: String) -> String {
        var t = text
        for pat in ["Nurbukkalem", "Nurbukh alum", "Nurbukh alum free"] {
            t = t.replacingOccurrences(of: pat, with: "NotebookLM")
        }
        return t
    }

    func summarize(transcript: String) async throws -> String {
        let clean = Self.normalizeMishears(transcript)
        let parts = Self.chunks(clean)
        var summaries: [String] = []
        for (i, c) in parts.enumerated() {
            let p = """
            This is part \(i + 1) of \(parts.count) of a live meeting/workshop transcript \
            (auto-transcribed; fix obvious mishears). Extract concisely as bullets: tools/websites \
            demoed, what was shown/done, step-by-step instructions, and any URLs. Bullets only.

            TRANSCRIPT PART \(i + 1):
            \(c)
            """
            summaries.append("### Segment \(i + 1)\n" + (try await llm.generate(prompt: p, system: nil)))
        }
        let reducePrompt = """
        You are compiling the FINAL notes for a meeting from ordered segment summaries. Produce clean \
        Markdown with: `## TL;DR` (3-4 sentences); `## Key Points`; `## Tools / Resources` (name — what \
        — link if mentioned); `## Action Items` as `- [ ]`. Merge duplicates. Do not invent.

        SEGMENT SUMMARIES:
        \(summaries.joined(separator: "\n\n"))
        """
        return try await llm.generate(prompt: reducePrompt, system: nil)
    }
}
