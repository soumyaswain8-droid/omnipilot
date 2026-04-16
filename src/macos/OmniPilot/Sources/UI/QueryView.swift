import SwiftUI

/// Main popover view with tabs: Query, Memories, Settings
struct QueryView: View {
    let memoryStore: MemoryStore
    let ollamaClient: OllamaClient
    let pipeline: Pipeline

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.purple)
                    .font(.title2)
                Text("OmniPilot")
                    .font(.headline)
                Spacer()
                StatusIndicator(ollamaClient: ollamaClient, memoryStore: memoryStore)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Ask").tag(0)
                Text("Memories").tag(1)
                Text("Settings").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Tab content
            switch selectedTab {
            case 0:
                AskTab(memoryStore: memoryStore, ollamaClient: ollamaClient, pipeline: pipeline)
            case 1:
                MemoryBrowserTab(memoryStore: memoryStore)
            case 2:
                SettingsTab(pipeline: pipeline)
            default:
                EmptyView()
            }
        }
        .frame(width: 420, height: 520)
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    let ollamaClient: OllamaClient
    let memoryStore: MemoryStore
    @State private var isOnline = false
    @State private var count = 0

    var body: some View {
        HStack(spacing: 6) {
            Text("\(count)")
                .font(.caption2)
                .foregroundColor(.secondary)
            Image(systemName: "memorychip")
                .font(.caption2)
                .foregroundColor(.secondary)

            Circle()
                .fill(isOnline ? Color.green : Color.red)
                .frame(width: 7, height: 7)
        }
        .onAppear {
            count = memoryStore.count()
            Task { isOnline = await ollamaClient.isAvailable() }
        }
    }
}

// MARK: - Ask Tab (OMNI-009)

struct AskTab: View {
    let memoryStore: MemoryStore
    let ollamaClient: OllamaClient
    let pipeline: Pipeline

    @State private var query = ""
    @State private var answer = ""
    @State private var isProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Query input
            HStack {
                TextField("What did I discuss about...?", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { askQuestion() }

                Button(action: askQuestion) {
                    if isProcessing {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(.purple)
                            .font(.title3)
                    }
                }
                .disabled(query.isEmpty || isProcessing)
                .buttonStyle(.borderless)
            }

            // Quick actions
            HStack(spacing: 8) {
                QuickButton(title: "Today's Summary", icon: "sun.max") {
                    generateDailySummary()
                }
                QuickButton(title: "Recent", icon: "clock") {
                    showRecent()
                }
                QuickButton(title: "People", icon: "person.2") {
                    query = "people mentioned today"
                    askQuestion()
                }
            }

            // Answer area
            if isProcessing {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("Thinking...").font(.caption).foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }

            if !answer.isEmpty {
                ScrollView {
                    Text(answer)
                        .font(.system(size: 12.5))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.purple.opacity(0.04))
                        .cornerRadius(8)
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
        .padding()
    }

    private func askQuestion() {
        guard !query.isEmpty, !isProcessing else { return }
        isProcessing = true
        answer = ""
        let q = query

        Task {
            do {
                answer = try await pipeline.query(q)
            } catch {
                answer = "Error: \(error.localizedDescription)"
            }
            isProcessing = false
        }
    }

    private func showRecent() {
        let recent = memoryStore.recent(limit: 5)
        if recent.isEmpty {
            answer = "No memories yet. Start talking and OmniPilot will remember."
            return
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        answer = recent.map { "[\(fmt.string(from: $0.timestamp))]\n\($0.content)" }
            .joined(separator: "\n\n---\n\n")
    }

    private func generateDailySummary() {
        isProcessing = true
        answer = ""
        Task {
            do {
                answer = try await pipeline.dailySummary()
            } catch {
                answer = "Error: \(error.localizedDescription)"
            }
            isProcessing = false
        }
    }
}

struct QuickButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.purple.opacity(0.08))
                .cornerRadius(6)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Memory Browser Tab (OMNI-010)

struct MemoryBrowserTab: View {
    let memoryStore: MemoryStore

    @State private var searchText = ""
    @State private var memories: [(id: Int64, content: String, timestamp: Date)] = []
    @State private var filterDate: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search memories...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { search() }

                if !searchText.isEmpty {
                    Button(action: { searchText = ""; loadRecent() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            // Filter buttons
            HStack(spacing: 6) {
                FilterChip(title: "All", isActive: filterDate == nil) {
                    filterDate = nil
                    loadRecent()
                }
                FilterChip(title: "Today", isActive: isToday(filterDate)) {
                    filterDate = Calendar.current.startOfDay(for: Date())
                    loadToday()
                }
                Spacer()
                Text("\(memories.count) results")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Memory list
            if memories.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "brain")
                        .font(.largeTitle)
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No memories yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Start talking and OmniPilot will remember.")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(memories, id: \.id) { memory in
                            MemoryCard(content: memory.content, timestamp: memory.timestamp)
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear { loadRecent() }
    }

    private func loadRecent() {
        memories = memoryStore.recent(limit: 50)
    }

    private func loadToday() {
        memories = memoryStore.todaysMemories()
    }

    private func search() {
        guard !searchText.isEmpty else { loadRecent(); return }
        let results = memoryStore.search(query: searchText, limit: 20)
        memories = results.map { ($0.id, $0.content, $0.timestamp) }
    }

    private func isToday(_ date: Date?) -> Bool {
        guard let d = date else { return false }
        return Calendar.current.isDateInToday(d)
    }
}

struct MemoryCard: View {
    let content: String
    let timestamp: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(content)
                .font(.system(size: 11.5))
                .lineLimit(4)
                .textSelection(.enabled)
            Text(timeAgo(timestamp))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
    }

    private func timeAgo(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

struct FilterChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(isActive ? Color.purple.opacity(0.15) : Color.gray.opacity(0.08))
                .foregroundColor(isActive ? .purple : .secondary)
                .cornerRadius(12)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Settings Tab (OMNI-010)

struct SettingsTab: View {
    let pipeline: Pipeline

    @AppStorage("listenMode") private var listenMode = "always"
    @AppStorage("summaryHour") private var summaryHour = 18
    @AppStorage("speechThreshold") private var speechThreshold = 0.01

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Listening
                GroupBox("Listening") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Mode", selection: $listenMode) {
                            Text("Always On").tag("always")
                            Text("Push-to-Talk").tag("ptt")
                            Text("Off").tag("off")
                        }
                        .onChange(of: listenMode) {
                            if listenMode == "off" {
                                pipeline.stop()
                            } else {
                                pipeline.start()
                            }
                        }

                        HStack {
                            Text("Speech sensitivity")
                                .font(.caption)
                            Slider(value: $speechThreshold, in: 0.005...0.05, step: 0.005)
                                .onChange(of: speechThreshold) {
                                    pipeline.vad.speechThreshold = Float(speechThreshold)
                                }
                        }
                    }
                    .padding(4)
                }

                // Daily Summary
                GroupBox("Daily Summary") {
                    Picker("Generate at", selection: $summaryHour) {
                        Text("5 PM").tag(17)
                        Text("6 PM").tag(18)
                        Text("7 PM").tag(19)
                        Text("8 PM").tag(20)
                        Text("9 PM").tag(21)
                    }
                    .padding(4)
                }

                // Info
                GroupBox("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        InfoRow(label: "Model", value: "llama3.2:3b")
                        InfoRow(label: "STT", value: "whisper.cpp (small.en)")
                        InfoRow(label: "Memory", value: "\(pipeline.memory.count()) entries")
                        InfoRow(label: "Hotkey", value: "Cmd+Shift+O")
                        InfoRow(label: "Privacy", value: "100% local, no cloud")
                    }
                    .padding(4)
                }

                // Danger zone
                GroupBox("Data") {
                    Button("Open Memory DB in Finder") {
                        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                        let omniDir = appSupport.appendingPathComponent("OmniPilot")
                        NSWorkspace.shared.open(omniDir)
                    }
                    .font(.caption)
                    .padding(4)
                }
            }
            .padding()
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.caption).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.caption).fontWeight(.medium)
        }
    }
}

// MARK: - Standalone Settings Window

struct SettingsView: View {
    var body: some View {
        Text("OmniPilot Settings — Use the menu bar popover for settings.")
            .padding()
            .frame(width: 300, height: 100)
    }
}
