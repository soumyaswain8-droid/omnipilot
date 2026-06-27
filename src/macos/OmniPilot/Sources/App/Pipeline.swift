import Foundation
import SQLite
import os.log

/// The main OmniPilot pipeline: Audio -> VAD -> Whisper -> Memory -> LLM
class Pipeline: @unchecked Sendable {
    /// Unified-logging handle — visible via `log stream --predicate 'subsystem == "in.sidewall.omnipilot"'`
    private static let log = Logger(subsystem: "in.sidewall.omnipilot", category: "Pipeline")

    let audioCapture: AudioCapture
    let whisper: WhisperBridge
    let memory: MemoryStore
    let ollama: OllamaClient
    let vad: SimpleVAD
    let taskStore: TaskStore
    let scheduler: TaskScheduler
    let intentParser: IntentParser

    private var isRunning = false
    private var speechBuffer: [Float] = []
    private let speechBufferLock = NSLock()

    /// VAD frame size (30ms at 16kHz)
    private let vadFrameSize = 480

    /// Minimum speech duration to transcribe (1 second)
    private let minSpeechSamples = 16000

    /// Callback for status updates
    var onStatusUpdate: ((String) -> Void)?
    var onTranscription: ((String) -> Void)?
    /// Callback when a task is created
    var onTaskCreated: ((String) -> Void)?

    init(audioCapture: AudioCapture, whisper: WhisperBridge, memory: MemoryStore, ollama: OllamaClient) {
        self.audioCapture = audioCapture
        self.whisper = whisper
        self.memory = memory
        self.ollama = ollama
        self.vad = SimpleVAD()

        // Initialize task system using the same DB connection
        // TaskStore needs its own connection since MemoryStore's is private
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let omniDir = appSupport.appendingPathComponent("OmniPilot")
        try? FileManager.default.createDirectory(at: omniDir, withIntermediateDirectories: true)
        let dbPath = omniDir.appendingPathComponent("memory.sqlite").path
        let taskDb = try! Connection(dbPath)
        self.taskStore = TaskStore(db: taskDb)
        self.scheduler = TaskScheduler(taskStore: taskStore)
        self.intentParser = IntentParser(ollama: ollama)

        setupAudioPipeline()

        // Start the task scheduler
        scheduler.start()
        scheduler.onTaskTriggered = { [weak self] action, desc in
            self?.onStatusUpdate?("Task triggered: \(desc)")
        }
    }

    private func setupAudioPipeline() {
        // Audio capture sends chunks (3s). We process through VAD frame by frame.
        audioCapture.onAudioChunk = { [weak self] chunk in
            self?.processAudioChunk(chunk)
        }
    }

    /// Process a 3-second audio chunk through VAD
    private func processAudioChunk(_ chunk: [Float]) {
        var offset = 0
        while offset + vadFrameSize <= chunk.count {
            let frame = Array(chunk[offset..<(offset + vadFrameSize)])
            let isSpeech = vad.process(samples: frame)

            speechBufferLock.lock()
            if isSpeech {
                speechBuffer.append(contentsOf: frame)
            } else if !speechBuffer.isEmpty && speechBuffer.count >= minSpeechSamples {
                // Speech ended — transcribe what we have
                let audio = speechBuffer
                speechBuffer.removeAll()
                speechBufferLock.unlock()

                onStatusUpdate?("Transcribing...")
                transcribeAndStore(audio: audio)
                offset += vadFrameSize
                continue
            } else if !isSpeech {
                // Silence but not enough speech collected — discard
                speechBuffer.removeAll()
            }
            speechBufferLock.unlock()

            offset += vadFrameSize
        }
    }

    /// Transcribe audio and store in memory
    private func transcribeAndStore(audio: [Float]) {
        // CRITICAL: Skip if OmniPilot is speaking — prevents feedback loop
        guard !VoiceOutput.shared.isSpeaking else {
            print("[Pipeline] Skipping — OmniPilot is speaking (echo prevention)")
            return
        }

        // Audio energy gate — if the whole buffer is quiet, it's ambient noise, not speech.
        // Threshold calibrated to allow quiet/close-mic speech through while still blocking
        // fan hum and keyboard clicks (which tend to sit below ~0.003 RMS).
        let rms = Self.calculateRMS(audio)
        Self.log.info("Audio RMS: \(rms, format: .fixed(precision: 5)), samples: \(audio.count)")
        // Lowered from 0.005 -> 0.0015: 0.005 silently dropped normal-volume speech from the
        // built-in mic (especially at arm's length), so only loud ambient audio got through.
        // 0.0015 still blocks fan hum / keyboard clicks which sit well below it.
        guard rms > 0.0015 else {
            Self.log.info("Skipping — audio too quiet (RMS \(rms, format: .fixed(precision: 5)))")
            onStatusUpdate?("Listening...")
            return
        }

        Task {
            do {
                let text = try await whisper.transcribe(audioSamples: audio)

                // Skip empty or very short transcriptions
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleaned.count > 5 else {
                    Self.log.info("Skipping — transcript too short (\(cleaned.count) chars): '\(cleaned, privacy: .public)'")
                    onStatusUpdate?("Listening...")
                    return
                }

                // Skip Whisper hallucinations (parenthetical/bracket annotations and common fillers)
                if Self.isHallucination(cleaned) {
                    Self.log.info("Skipping — hallucination: \(cleaned.prefix(60), privacy: .public)")
                    onStatusUpdate?("Listening...")
                    return
                }

                Self.log.info("Transcribed: \(cleaned.prefix(80), privacy: .public)")
                onTranscription?(cleaned)

                // Wake-phrase detection — "Hey Pilot, <question>" routes to hands-free query
                if let query = Self.stripWakePhrase(cleaned) {
                    print("[Pipeline] Wake phrase detected. Query: \(query)")
                    self.onStatusUpdate?("Thinking...")
                    do {
                        let answer = try await self.query(query, speakAnswer: true)
                        self.onTranscription?("> \(query)\n\n\(answer)")
                    } catch {
                        print("[Pipeline] Wake query failed: \(error)")
                        VoiceOutput.shared.speak("Sorry, I couldn't answer that.")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.onStatusUpdate?("Listening...")
                    }
                    return
                }

                // Check if this is a voice COMMAND (task/reminder) before storing as memory
                if IntentParser.looksLikeTask(cleaned) {
                    Self.log.info("Detected voice command: \(cleaned, privacy: .public)")
                    do {
                        let confirmation = try await self.createTask(from: cleaned)
                        self.onTranscription?("✓ \(confirmation)")
                        self.onStatusUpdate?("Task created!")
                    } catch {
                        print("[Pipeline] Task creation failed: \(error)")
                        // Still store as memory if task creation fails
                        memory.storeWithEmbedding(text: cleaned, source: "mic", type: "transcription")
                    }
                } else {
                    // Regular speech — store as memory
                    memory.storeWithEmbedding(text: cleaned, source: "mic", type: "transcription")
                    Self.log.info("Stored memory — \(self.memory.count()) total")
                    onStatusUpdate?("Stored. \(memory.count()) memories total.")
                }

                // Reset status after a moment
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.onStatusUpdate?("Listening...")
                }

            } catch {
                Self.log.error("Transcription error: \(error.localizedDescription, privacy: .public)")
                onStatusUpdate?("Listening...")
            }
        }
    }

    /// Start the full pipeline
    func start() {
        guard !isRunning else { return }
        isRunning = true
        audioCapture.startCapture()
        onStatusUpdate?("Listening...")
        Self.log.info("Started — listening for speech")
        // Safety net: re-embed any memories whose embedding failed at store time.
        memory.backfillMissingEmbeddings()
    }

    /// Stop the pipeline
    func stop() {
        guard isRunning else { return }
        isRunning = false
        audioCapture.stopCapture()

        // Flush any remaining speech
        speechBufferLock.lock()
        if speechBuffer.count >= minSpeechSamples {
            let remaining = speechBuffer
            speechBuffer.removeAll()
            speechBufferLock.unlock()
            transcribeAndStore(audio: remaining)
        } else {
            speechBuffer.removeAll()
            speechBufferLock.unlock()
        }

        onStatusUpdate?("Stopped")
        print("[Pipeline] Stopped")
    }

    /// Smart query: detects if input is a task/reminder or a memory question
    func query(_ question: String, speakAnswer: Bool = false) async throws -> String {
        // Check if this looks like a task/reminder command
        if IntentParser.looksLikeTask(question) {
            return try await createTask(from: question)
        }

        // Otherwise, search memories
        let results = await memory.semanticSearch(query: question, limit: 5)

        if results.isEmpty {
            let msg = "No memories found matching '\(question)'. Try different keywords, or make sure I've been listening to conversations about this topic."
            if speakAnswer { VoiceOutput.shared.speak(msg) }
            return msg
        }

        let context = results.map { $0.content }
        let answer = try await ollama.answerQuestion(question: question, context: context)
        if speakAnswer { VoiceOutput.shared.speak(answer) }
        return answer
    }

    /// Create a scheduled task from natural language
    func createTask(from input: String) async throws -> String {
        guard let intent = try await intentParser.parse(input) else {
            return "I couldn't understand that as a task. Try: 'Remind me to call Kishore tomorrow at 4 PM'"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let timeStr = formatter.string(from: intent.scheduledAt)

        // Create the task
        taskStore.create(
            actionType: intent.action,
            desc: intent.description,
            msg: intent.message,
            recipientName: intent.recipient,
            phoneNumber: intent.phone,
            scheduleDate: intent.scheduledAt,
            confirmation: "Task set for \(timeStr)"
        )

        // Build SHORT confirmation — just task + time
        let shortTime: String
        let interval = intent.scheduledAt.timeIntervalSinceNow
        if interval < 3600 {
            shortTime = "in \(Int(interval / 60)) minutes"
        } else if interval < 86400 {
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            shortTime = "at \(fmt.string(from: intent.scheduledAt))"
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEEE h:mm a"
            shortTime = fmt.string(from: intent.scheduledAt)
        }

        let confirmation: String
        switch intent.action {
        case "whatsapp":
            confirmation = "Will message \(intent.recipient ?? "them") \(shortTime)."
        case "call":
            confirmation = "Will remind you to call \(intent.recipient ?? "them") \(shortTime)."
        default:
            confirmation = "\(intent.description), \(shortTime)."
        }

        // Speak SHORT confirmation
        VoiceOutput.shared.speak(confirmation)
        onTaskCreated?(confirmation)

        return confirmation + "\n\nPending tasks: \(taskStore.pendingCount())"
    }

    /// Get all pending tasks
    func getPendingTasks() -> [(id: Int64, action: String, description: String, recipient: String?, scheduledAt: Date)] {
        taskStore.pendingTasks()
    }

    /// Cancel a task
    func cancelTask(_ taskId: Int64) {
        taskStore.cancel(taskId)
    }

    /// Generate daily summary — speaks it aloud
    func dailySummary() async throws -> String {
        let todays = memory.todaysMemories()
        if todays.isEmpty {
            return "No conversations recorded today yet."
        }

        let texts = todays.map { $0.content }
        let summary = try await ollama.dailySummary(memories: texts)

        // Store summary as a memory
        let _ = memory.store(text: summary, source: "system", type: "daily_summary")

        // Speak it aloud
        VoiceOutput.shared.speakSummary(summary)

        return summary
    }

    /// Schedule daily summary at a specific hour (OMNI-008)
    private var summaryTimer: Timer?

    func scheduleDailySummary(hour: Int = 18) {
        summaryTimer?.invalidate()

        // Calculate next fire date
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = 0

        guard var fireDate = calendar.date(from: components) else { return }

        // If we've passed the hour today, schedule for tomorrow
        if fireDate <= Date() {
            fireDate = calendar.date(byAdding: .day, value: 1, to: fireDate)!
        }

        let interval = fireDate.timeIntervalSinceNow

        summaryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task {
                guard let self = self else { return }
                do {
                    let summary = try await self.dailySummary()
                    self.showNotification(title: "OmniPilot Daily Summary", body: String(summary.prefix(200)))
                    // Reschedule for tomorrow
                    self.scheduleDailySummary(hour: hour)
                } catch {
                    print("[Pipeline] Daily summary error: \(error)")
                }
            }
        }

        print("[Pipeline] Daily summary scheduled for \(fireDate)")
    }

    private func showNotification(title: String, body: String) {
        NotificationHelper.shared.send(title: title, body: body)
    }

    /// Root-mean-square amplitude of a Float PCM buffer. Used to gate low-energy audio.
    static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Detect common Whisper hallucinations on silent/noisy audio.
    /// Whisper tends to output bracketed annotations or stock phrases when fed near-silence.
    static func isHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Anything that's entirely a parenthetical/bracket annotation is metadata, not speech.
        // E.g. "(speaking foreign language)", "[music]", "(footsteps)"
        if trimmed.first == "(" && trimmed.last == ")" { return true }
        if trimmed.first == "[" && trimmed.last == "]" { return true }
        if trimmed.hasPrefix("- ") && trimmed.count < 30 { return true }

        // Known stock-phrase hallucinations — Whisper produces these when fed silence
        let stockHallucinations = [
            "thank you.", "thank you!", "thanks for watching",
            "bonjour!", "bonjour.", "subscribe to",
            "see you next time", "see you in the next",
            "please subscribe", "like and subscribe",
            "www.", "http", ".com", ".org",
        ]
        for phrase in stockHallucinations where lower.contains(phrase) && trimmed.count < 40 {
            return true
        }

        return false
    }

    /// Strip a wake phrase from the start of a transcription. Returns the remaining query,
    /// or nil if no wake phrase is present.
    /// Accepts: "hey pilot", "hey omni", "hey omnipilot", "ok pilot", "okay pilot"
    static func stripWakePhrase(_ text: String) -> String? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let phrases = ["hey pilot", "hey omnipilot", "hey omni", "okay pilot", "ok pilot"]
        for phrase in phrases where lower.hasPrefix(phrase) {
            // Find the original-case cut point, skip phrase + any trailing comma/space
            let rest = text.dropFirst(phrase.count)
            let trimmed = rest.drop(while: { " ,.:".contains($0) })
            let query = String(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? nil : query
        }
        return nil
    }
}
