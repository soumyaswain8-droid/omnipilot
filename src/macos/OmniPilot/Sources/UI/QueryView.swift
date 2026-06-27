import SwiftUI

// MARK: - Main View

struct QueryView: View {
    let memoryStore: MemoryStore
    let ollamaClient: OllamaClient
    let pipeline: Pipeline

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(pipeline: pipeline, memoryStore: memoryStore, ollamaClient: ollamaClient)

            TabSelector(selectedTab: $selectedTab)

            Divider()

            Group {
                switch selectedTab {
                case 0: LiveFeedTab(pipeline: pipeline, memoryStore: memoryStore)
                case 1: AskTab(pipeline: pipeline, memoryStore: memoryStore)
                case 2: TasksTab(pipeline: pipeline)
                case 3: MemoryBrowserTab(memoryStore: memoryStore)
                case 4: SettingsTab(pipeline: pipeline)
                default: EmptyView()
                }
            }
        }
        .frame(width: 460, height: 580)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Header

struct HeaderBar: View {
    let pipeline: Pipeline
    let memoryStore: MemoryStore
    let ollamaClient: OllamaClient

    @State private var isListening = true
    @State private var memCount = 0
    @State private var ollamaOnline = false
    @State private var vadMode = "energy"

    var body: some View {
        HStack(spacing: 10) {
            // App icon + name
            HStack(spacing: 6) {
                Circle()
                    .fill(isListening
                        ? LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [.gray, .gray.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: isListening ? "waveform" : "pause")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("OmniPilot")
                        .font(.system(size: 13, weight: .bold))
                    Text(isListening ? "Listening" : "Paused")
                        .font(.system(size: 10))
                        .foregroundColor(isListening ? .green : .secondary)
                }
            }

            Spacer()

            // Status pills
            HStack(spacing: 6) {
                StatusPill(
                    icon: "memorychip",
                    text: "\(memCount)",
                    color: .purple
                )
                StatusPill(
                    icon: "brain",
                    text: ollamaOnline ? "AI" : "Off",
                    color: ollamaOnline ? .green : .red
                )
                StatusPill(
                    icon: "waveform.badge.mic",
                    text: vadMode,
                    color: vadMode == "silero" ? .blue : .orange
                )
            }

            // Listen toggle
            Button(action: {
                isListening.toggle()
                if isListening { pipeline.start() } else { pipeline.stop() }
            }) {
                Image(systemName: isListening ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(isListening ? .orange : .green)
            }
            .buttonStyle(.borderless)
            .help(isListening ? "Pause listening" : "Start listening")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            memCount = memoryStore.count()
            vadMode = pipeline.vad.isSileroActive ? "silero" : "energy"
            Task { ollamaOnline = await ollamaClient.isAvailable() }
        }
    }
}

struct StatusPill: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .foregroundColor(color)
        .cornerRadius(8)
    }
}

// MARK: - Tab Selector

struct TabSelector: View {
    @Binding var selectedTab: Int

    private let tabs = [
        (icon: "waveform", label: "Live"),
        (icon: "magnifyingglass", label: "Ask"),
        (icon: "checklist", label: "Tasks"),
        (icon: "clock", label: "Memories"),
        (icon: "gearshape", label: "Settings"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<tabs.count, id: \.self) { i in
                Button(action: { selectedTab = i }) {
                    VStack(spacing: 3) {
                        Image(systemName: tabs[i].icon)
                            .font(.system(size: 13))
                        Text(tabs[i].label)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundColor(selectedTab == i ? .purple : .secondary)
                    .background(selectedTab == i ? Color.purple.opacity(0.08) : Color.clear)
                    .cornerRadius(6)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

// MARK: - Live Feed Tab (OMNI-018)

struct LiveFeedTab: View {
    let pipeline: Pipeline
    let memoryStore: MemoryStore

    @State private var liveLines: [(id: UUID, text: String, time: Date)] = []
    @State private var status = "Waiting for speech..."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status bar
            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .opacity(status.contains("Listening") ? 1 : 0.3)
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(memoryStore.count()) stored")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Live transcription feed
            if liveLines.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 36))
                        .foregroundColor(.purple.opacity(0.3))
                    Text("Speak and your words will appear here")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("OmniPilot is listening and remembering")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(liveLines, id: \.id) { line in
                                LiveLineView(text: line.text, time: line.time)
                                    .id(line.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: liveLines.count) {
                        if let last = liveLines.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            // Quick actions bar
            HStack(spacing: 8) {
                QuickActionButton(icon: "sun.max", label: "Summary") {
                    // Will be wired to daily summary
                }
                QuickActionButton(icon: "arrow.counterclockwise", label: "Clear Feed") {
                    liveLines.removeAll()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .onAppear {
            pipeline.onTranscription = { text in
                DispatchQueue.main.async {
                    liveLines.append((UUID(), text, Date()))
                    // Keep only last 50 lines
                    if liveLines.count > 50 { liveLines.removeFirst() }
                }
            }
            pipeline.onStatusUpdate = { s in
                DispatchQueue.main.async { status = s }
            }
        }
    }
}

struct LiveLineView: View {
    let text: String
    let time: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeString)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.purple.opacity(0.6))
                .frame(width: 45, alignment: .trailing)

            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.purple.opacity(0.03))
        .cornerRadius(6)
    }

    private var timeString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: time)
    }
}

struct QuickActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.purple.opacity(0.08))
            .cornerRadius(6)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Ask Tab (OMNI-009)

struct AskTab: View {
    let pipeline: Pipeline
    let memoryStore: MemoryStore

    @State private var query = ""
    @State private var answer = ""
    @State private var isProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Query input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.purple)
                    .font(.system(size: 14))

                TextField("What did I discuss about...?", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { askQuestion() }

                if isProcessing {
                    ProgressView().scaleEffect(0.6)
                } else if !query.isEmpty {
                    Button(action: askQuestion) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.purple)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(10)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.2), lineWidth: 1))

            // Quick queries
            HStack(spacing: 6) {
                QuickQueryChip(text: "Today's summary") {
                    query = ""; generateSummary()
                }
                QuickQueryChip(text: "Recent decisions") {
                    query = "decisions made recently"; askQuestion()
                }
                QuickQueryChip(text: "Action items") {
                    query = "action items and tasks"; askQuestion()
                }
            }

            // Answer
            if isProcessing {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Thinking...").font(.system(size: 11)).foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }

            if !answer.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(answer)
                            .font(.system(size: 12))
                            .textSelection(.enabled)

                        HStack {
                            Spacer()
                            Button(action: { VoiceOutput.shared.speak(answer) }) {
                                Label("Speak", systemImage: "speaker.wave.2")
                                    .font(.system(size: 9.5))
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.purple)

                            Button(action: { VoiceOutput.shared.stop() }) {
                                Label("Stop", systemImage: "stop.circle")
                                    .font(.system(size: 9.5))
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.purple.opacity(0.04))
                    .cornerRadius(10)
                }
            }

            Spacer()
        }
        .padding(14)
    }

    private func askQuestion() {
        guard !query.isEmpty, !isProcessing else { return }
        isProcessing = true; answer = ""
        let q = query
        Task {
            do { answer = try await pipeline.query(q) }
            catch { answer = "Error: \(error.localizedDescription)" }
            isProcessing = false
        }
    }

    private func generateSummary() {
        isProcessing = true; answer = ""
        Task {
            do { answer = try await pipeline.dailySummary() }
            catch { answer = "Error: \(error.localizedDescription)" }
            isProcessing = false
        }
    }
}

struct QuickQueryChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(12)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Memory Browser Tab

struct MemoryBrowserTab: View {
    let memoryStore: MemoryStore

    @State private var searchText = ""
    @State private var memories: [(id: Int64, content: String, timestamp: Date)] = []
    @State private var showToday = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search memories...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { search() }
                if !searchText.isEmpty {
                    Button(action: { searchText = ""; loadRecent() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }.buttonStyle(.borderless)
                }
            }
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Filters
            HStack(spacing: 6) {
                FilterPill(title: "All", active: !showToday) { showToday = false; loadRecent() }
                FilterPill(title: "Today", active: showToday) { showToday = true; loadToday() }
                Spacer()
                Text("\(memories.count) memories")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // List
            if memories.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "brain")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("No memories yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(memories, id: \.id) { m in
                            MemoryRow(content: m.content, timestamp: m.timestamp)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .onAppear { loadRecent() }
    }

    private func loadRecent() { memories = memoryStore.recent(limit: 50) }
    private func loadToday() { memories = memoryStore.todaysMemories() }
    private func search() {
        guard !searchText.isEmpty else { loadRecent(); return }
        memories = memoryStore.search(query: searchText, limit: 30).map { ($0.id, $0.content, $0.timestamp) }
    }
}

struct MemoryRow: View {
    let content: String
    let timestamp: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(content)
                .font(.system(size: 11))
                .lineLimit(3)
                .textSelection(.enabled)
            Text(RelativeDateTimeFormatter().localizedString(for: timestamp, relativeTo: Date()))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct FilterPill: View {
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(active ? Color.purple.opacity(0.12) : Color.gray.opacity(0.06))
                .foregroundColor(active ? .purple : .secondary)
                .cornerRadius(10)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Tasks Tab

struct TasksTab: View {
    let pipeline: Pipeline

    @State private var newTask = ""
    @State private var isProcessing = false
    @State private var confirmation = ""
    @State private var tasks: [(id: Int64, action: String, description: String, recipient: String?, scheduledAt: Date)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Task input
            VStack(alignment: .leading, spacing: 6) {
                Text("Tell OmniPilot what to do:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.purple)
                        .font(.system(size: 14))
                    TextField("Remind me to call Kishore tomorrow at 4 PM", text: $newTask)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { createTask() }
                    if isProcessing {
                        ProgressView().scaleEffect(0.6)
                    } else if !newTask.isEmpty {
                        Button(action: createTask) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.purple)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(10)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.2), lineWidth: 1))

                // Quick examples
                HStack(spacing: 4) {
                    Text("Try:").font(.system(size: 9)).foregroundColor(.secondary)
                    QuickQueryChip(text: "Remind me in 30 min") {
                        newTask = "Remind me to take a break in 30 minutes"
                        createTask()
                    }
                    QuickQueryChip(text: "WhatsApp at 5 PM") {
                        newTask = "Send WhatsApp to Kishore at 5 PM saying let's catch up"
                        createTask()
                    }
                }
            }
            .padding(12)

            // Confirmation
            if !confirmation.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 14))
                    Text(confirmation)
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()

            // Pending tasks list
            if tasks.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "checklist")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("No pending tasks")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Type a reminder or task above")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(tasks, id: \.id) { task in
                            TaskRow(
                                task: task,
                                onCancel: {
                                    pipeline.cancelTask(task.id)
                                    refreshTasks()
                                }
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
        .onAppear { refreshTasks() }
    }

    private func createTask() {
        guard !newTask.isEmpty, !isProcessing else { return }
        isProcessing = true
        confirmation = ""
        let input = newTask
        newTask = ""

        Task {
            do {
                confirmation = try await pipeline.createTask(from: input)
                refreshTasks()
            } catch {
                confirmation = "Error: \(error.localizedDescription)"
            }
            isProcessing = false

            // Clear confirmation after 5 seconds
            try? await Swift.Task.sleep(for: .seconds(5))
            confirmation = ""
        }
    }

    private func refreshTasks() {
        tasks = pipeline.getPendingTasks()
    }
}

struct TaskRow: View {
    let task: (id: Int64, action: String, description: String, recipient: String?, scheduledAt: Date)
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Action icon
            Image(systemName: actionIcon)
                .font(.system(size: 14))
                .foregroundColor(actionColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.description)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if let recipient = task.recipient {
                        Text(recipient)
                            .font(.system(size: 9))
                            .foregroundColor(.purple)
                    }
                    Text(timeUntil)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Cancel task")
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    private var actionIcon: String {
        switch task.action {
        case "whatsapp": return "message.fill"
        case "email": return "envelope.fill"
        case "call": return "phone.fill"
        default: return "bell.fill"
        }
    }

    private var actionColor: Color {
        switch task.action {
        case "whatsapp": return .green
        case "email": return .blue
        case "call": return .orange
        default: return .purple
        }
    }

    private var timeUntil: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: task.scheduledAt, relativeTo: Date())
    }
}

// MARK: - Settings Tab

struct SettingsTab: View {
    let pipeline: Pipeline

    @AppStorage("listenMode") private var listenMode = "always"
    @AppStorage("summaryHour") private var summaryHour = 18
    @AppStorage("speechThreshold") private var speechThreshold = 0.01

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsGroup(title: "Listening") {
                    Picker("Mode", selection: $listenMode) {
                        Text("Always On").tag("always")
                        Text("Push-to-Talk").tag("ptt")
                        Text("Off").tag("off")
                    }
                    .onChange(of: listenMode) {
                        if listenMode == "off" { pipeline.stop() } else { pipeline.start() }
                    }

                    HStack {
                        Text("Speech sensitivity").font(.system(size: 11))
                        Slider(value: $speechThreshold, in: 0.005...0.05, step: 0.005)
                            .onChange(of: speechThreshold) {
                                pipeline.vad.speechThreshold = Float(speechThreshold)
                            }
                    }

                    HStack {
                        Text("VAD Engine").font(.system(size: 11))
                        Spacer()
                        Text(pipeline.vad.isSileroActive ? "Silero (Neural)" : "Energy (Basic)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(pipeline.vad.isSileroActive ? .green : .orange)
                    }

                    if !pipeline.vad.isSileroActive {
                        Button("Reconnect Silero") { pipeline.vad.reconnectSilero() }
                            .font(.system(size: 10))
                    }
                }

                SettingsGroup(title: "Daily Summary") {
                    Picker("Generate at", selection: $summaryHour) {
                        ForEach(17...21, id: \.self) { h in
                            Text("\(h > 12 ? h - 12 : h) \(h >= 12 ? "PM" : "AM")").tag(h)
                        }
                    }
                }

                SettingsGroup(title: "Voice Output") {
                    Toggle("Speak reminders aloud", isOn: Binding(
                        get: { VoiceOutput.shared.enabled },
                        set: { VoiceOutput.shared.enabled = $0 }
                    ))
                    .font(.system(size: 11))

                    HStack {
                        Text("Voice").font(.system(size: 11))
                        Spacer()
                        Picker("", selection: .constant("indian")) {
                            Text("Aman (Indian)").tag("indian")
                            Text("Daniel (British)").tag("british")
                            Text("Samantha (US)").tag("american")
                        }
                        .frame(width: 140)
                        .onChange(of: "indian") {
                            // Voice change handled by picker
                        }
                    }

                    Button("Test Voice") {
                        VoiceOutput.shared.speak("Hello! I'm OmniPilot, your personal AI assistant.")
                    }
                    .font(.system(size: 10))
                }

                SettingsGroup(title: "About") {
                    InfoLine(label: "LLM", value: "qwen3:8b (local)")
                    InfoLine(label: "STT", value: "whisper.cpp (small.en)")
                    InfoLine(label: "Memories", value: "\(pipeline.memory.count())")
                    InfoLine(label: "Hotkey", value: "Cmd+Shift+O")
                    InfoLine(label: "Privacy", value: "100% on-device")
                    InfoLine(label: "Version", value: "0.3.0")
                }

                SettingsGroup(title: "Data") {
                    Button("Open Memory DB in Finder") {
                        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            .appendingPathComponent("OmniPilot")
                        NSWorkspace.shared.open(dir)
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(14)
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.purple)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 6) { content }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
        }
    }
}

struct InfoLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium))
        }
    }
}

// MARK: - Standalone Settings Window

struct SettingsView: View {
    var body: some View {
        Text("Use the menu bar popover for settings.")
            .padding()
            .frame(width: 300, height: 80)
    }
}
