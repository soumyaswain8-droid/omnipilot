import Foundation

protocol Transcribing: Sendable { func transcribe(audioSamples: [Float]) async throws -> String }
extension WhisperBridge: Transcribing {}

/// Pulls new audio windows from the recorder and appends transcribed text.
actor MeetingTranscriber {
    private let recorder: MeetingRecorder
    private let whisper: Transcribing
    private let sampleRate: Int
    private var offset = 0
    private var builder = TranscriptBuilder()

    init(recorder: MeetingRecorder, whisper: Transcribing, sampleRate: Int = 16_000) {
        self.recorder = recorder
        self.whisper = whisper
        self.sampleRate = sampleRate
    }

    /// Transcribe whatever new audio exists since the last tick.
    func tick() async {
        let startSec = offset / sampleRate
        let window = recorder.windowSince(offset)
        guard !window.samples.isEmpty else { return }
        do {
            let text = try await whisper.transcribe(audioSamples: window.samples)
            builder.append(startSeconds: startSec, rawText: text)
            offset = window.newOffset
        } catch {
            // leave offset unchanged; retried next tick
        }
    }

    func flush() async { await tick() }
    func transcriptMarkdown(recordingName: String) -> String { builder.markdown(recordingName: recordingName) }
    func transcriptText() -> String { builder.plainText() }
    var isEmpty: Bool { builder.isEmpty }
}
