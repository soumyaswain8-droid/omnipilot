import Foundation

/// Accumulates transcript windows and renders raw ground-truth transcript.
struct TranscriptBuilder {
    private(set) var entries: [TranscriptEntry] = []
    var isEmpty: Bool { entries.isEmpty }

    /// Append a transcription window. Trims, drops empties and hallucinations.
    mutating func append(startSeconds: Int, rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Pipeline.isHallucination(text) else { return }
        entries.append(TranscriptEntry(startSeconds: startSeconds, text: text))
    }

    private func stamp(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }

    func markdown(recordingName: String) -> String {
        var out = "# Meeting Transcript\n\n_Recording: `\(recordingName)`_\n\n"
        for e in entries { out += "**[\(stamp(e.startSeconds))]** \(e.text)\n\n" }
        return out
    }

    func plainText() -> String { entries.map { $0.text }.joined(separator: " ") }
}
