import Foundation
import SQLite

/// The main OmniPilot pipeline: Audio -> VAD -> Whisper -> Memory -> LLM
class Pipeline: @unchecked Sendable {
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

        Task {
            do {
                let text = try await whisper.transcribe(audioSamples: audio)

                // Skip empty or very short transcriptions
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleaned.count > 5 else {
                    onStatusUpdate?("Listening...")
                    return
                }

                // Skip common noise transcriptions
                let noisePatterns = ["[BLANK_AUDIO]", "(music)", "[Music]", "(silence)", "Thank you."]
                if noisePatterns.contains(where: { cleaned.contains($0) }) && cleaned.count < 20 {
                    onStatusUpdate?("Listening...")
                    return
                }

                print("[Pipeline] Transcribed: \(cleaned.prefix(80))...")
                onTranscription?(cleaned)

                // Check if this is a voice COMMAND (task/reminder) before storing as memory
                if IntentParser.looksLikeTask(cleaned) {
                    print("[Pipeline] Detected voice command: \(cleaned)")
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
                    onStatusUpdate?("Stored. \(memory.count()) memories total.")
                }

                // Reset status after a moment
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.onStatusUpdate?("Listening...")
                }

            } catch {
                print("[Pipeline] Transcription error: \(error)")
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
        print("[Pipeline] Started — listening for speech")
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
}
