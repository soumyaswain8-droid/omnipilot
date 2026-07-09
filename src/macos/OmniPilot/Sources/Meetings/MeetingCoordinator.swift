import Foundation

protocol MeetingClock: Sendable { func elapsedSeconds(since start: Date) -> TimeInterval }
struct RealClock: MeetingClock { func elapsedSeconds(since start: Date) -> TimeInterval { Date().timeIntervalSince(start) } }

/// Sequences a meeting: pause assistant → record → transcribe (rolling) → summarize → publish → resume.
@MainActor
final class MeetingCoordinator {
    private(set) var state: MeetingState = .idle { didSet { onStateChange?(state) } }
    var onStateChange: ((MeetingState) -> Void)?

    private let assistant: Pipeline?
    private let whisper: WhisperBridge
    private let ollama: OllamaClient
    private let archiveRoot: URL
    private let config: MeetingConfig
    private let clock: MeetingClock

    private var recorder: MeetingRecorder?
    private var transcriber: MeetingTranscriber?
    private var rollTimer: Timer?
    private var startedAt = Date()
    private var audioURL: URL?

    init(assistant: Pipeline?, whisper: WhisperBridge, ollama: OllamaClient,
         archiveRoot: URL, config: MeetingConfig, clock: MeetingClock = RealClock()) {
        self.assistant = assistant; self.whisper = whisper; self.ollama = ollama
        self.archiveRoot = archiveRoot; self.config = config; self.clock = clock
    }

    func handle(_ event: MeetingEvent) {
        switch event {
        case .started: beginRecording()
        case .ended: Task { await finalize() }
        }
    }

    private func beginRecording() {
        guard state == .idle else { return }
        assistant?.stop()
        startedAt = Date()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meeting-\(UUID().uuidString).m4a")
        audioURL = tmp
        let rec = MeetingRecorder(capture: AudioCapture())
        try? rec.start(writingTo: tmp)
        let t = MeetingTranscriber(recorder: rec, whisper: whisper)
        recorder = rec; transcriber = t
        let timer = Timer(timeInterval: 90, repeats: true) { _ in Task { await t.tick() } }
        RunLoop.main.add(timer, forMode: .common); rollTimer = timer
        state = .recording
    }

    private func finalize() async {
        guard state == .recording, let rec = recorder, let t = transcriber else { return }
        rollTimer?.invalidate(); rollTimer = nil
        state = .finalizing
        _ = rec.stop()
        let elapsed = clock.elapsedSeconds(since: startedAt)

        if elapsed < config.minMeeting {           // discard short/false meetings
            cleanupTemp(); resetToIdle(); return
        }
        await t.flush()
        let transcriptText = await t.transcriptText()
        let transcriptMD = await t.transcriptMarkdown(recordingName: "audio.m4a")
        let notes: String
        if transcriptText.isEmpty {
            notes = "# Meeting Notes\n\n_Transcription unavailable._"
        } else if await ollama.isAvailable() {
            let s = MeetingSummarizer(llm: ollama)
            notes = (try? await s.summarize(transcript: transcriptText))
                ?? "# Meeting Notes\n\n_Summary failed._\n"
        } else {
            notes = "# Meeting Notes\n\n_Summary unavailable (Ollama offline)._"
        }
        state = .publishing
        let pub = ArchivePublisher(layout: ArchiveLayout(root: archiveRoot))
        _ = try? pub.publish(date: startedAt, title: nil, notes: notes,
                             transcript: transcriptMD, audio: audioURL)
        resetToIdle()
    }

    private func cleanupTemp() { if let u = audioURL { try? FileManager.default.removeItem(at: u) } }
    private func resetToIdle() {
        recorder = nil; transcriber = nil; audioURL = nil
        assistant?.start(); state = .idle
    }
}

#if DEBUG
extension MeetingCoordinator {
    struct FixedClock: MeetingClock { let s: TimeInterval; func elapsedSeconds(since start: Date) -> TimeInterval { s } }
    static func makeForTesting(archiveRoot: URL, elapsed: TimeInterval) -> MeetingCoordinator {
        MeetingCoordinator(assistant: nil, whisper: WhisperBridge(), ollama: OllamaClient(),
                           archiveRoot: archiveRoot, config: MeetingConfig(),
                           clock: FixedClock(s: elapsed))
    }
    func handleAndWait(_ event: MeetingEvent) async {
        handle(event)
        // finalize() runs in a Task; poll until idle (bounded).
        for _ in 0..<50 where state != .idle { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
}
#endif
