import Foundation

/// Client for Ollama REST API (localhost:11434)
class OllamaClient: @unchecked Sendable {
    private let baseURL = "http://localhost:11434"
    /// Preferred model first. Runtime picks the first one that Ollama has loaded.
    private let preferredModels = ["qwen3:8b", "llama3.2:3b"]
    private var model: String = "qwen3:8b"
    private let session = URLSession.shared

    init() {
        selectBestAvailableModel()
    }

    /// Query Ollama's model list once at startup and pick the highest-preference match.
    /// Runs synchronously (short request) so the chosen model is ready before any generate() call.
    private func selectBestAvailableModel() {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var names: [String] = []
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = obj["models"] as? [[String: Any]] {
                names = models.compactMap { $0["name"] as? String }
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2)

        for candidate in preferredModels where names.contains(candidate) {
            model = candidate
            print("[Ollama] Using model: \(candidate)")
            return
        }
        print("[Ollama] No preferred model loaded — defaulting to \(model)")
    }

    /// Generate a response from the LLM
    /// Handles Qwen3's thinking mode: extracts from both 'response' and 'thinking' fields
    func generate(prompt: String, system: String? = nil) async throws -> String {
        let url = URL(string: "\(baseURL)/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var messages: [[String: String]] = []
        if let system = system {
            messages.append(["role": "system", "content": system])
        }
        // Append /no_think to suppress thinking mode for faster responses
        messages.append(["role": "user", "content": prompt + "\n/no_think"])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "options": [
                "temperature": 0.3,
                "num_predict": 1024
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OllamaError.requestFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            throw OllamaError.invalidResponse
        }

        // Qwen3 puts output in 'content' (normal) or 'thinking' (when in think mode)
        let content = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let thinking = (message["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer content (actual response), fall back to thinking if content is empty
        if !content.isEmpty {
            return content
        } else if !thinking.isEmpty {
            // Extract just the conclusion from thinking (last sentence or paragraph)
            let lines = thinking.components(separatedBy: "\n").filter { !$0.isEmpty }
            // Return last meaningful chunk
            return lines.suffix(3).joined(separator: "\n")
        }

        return "No response generated."
    }

    /// Summarize a transcription
    func summarize(text: String) async throws -> String {
        let system = """
        You are OmniPilot, a personal AI memory assistant. Summarize the following transcription concisely.
        Extract: key points, people mentioned, decisions made, action items.
        Be brief — max 3-4 bullet points. Use plain language.
        """
        return try await generate(prompt: "Summarize this conversation:\n\n\(text)", system: system)
    }

    /// Answer a question using memory context
    func answerQuestion(question: String, context: [String]) async throws -> String {
        let contextText = context.enumerated()
            .map { "[\($0.offset + 1)] \($0.element)" }
            .joined(separator: "\n\n")

        let system = """
        You are OmniPilot, a personal AI memory assistant. Answer the user's question based ONLY on
        the memory context provided. If the answer isn't in the context, say so honestly.
        Be concise and direct. Reference which memory you're drawing from.
        """

        let prompt = """
        MEMORY CONTEXT:
        \(contextText)

        QUESTION: \(question)

        Answer based on the memories above:
        """

        return try await generate(prompt: prompt, system: system)
    }

    /// Extract entities (people, topics, decisions) from text
    func extractEntities(text: String) async throws -> (people: [String], topics: [String], decisions: [String]) {
        let system = """
        Extract entities from this text. Return ONLY a JSON object with three arrays:
        {"people": [...], "topics": [...], "decisions": [...]}
        If none found for a category, return an empty array. No explanation, just JSON.
        """

        let response = try await generate(prompt: text, system: system)

        // Parse JSON response
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            return ([], [], [])
        }

        return (
            people: json["people"] ?? [],
            topics: json["topics"] ?? [],
            decisions: json["decisions"] ?? []
        )
    }

    /// Generate end-of-day summary
    func dailySummary(memories: [String]) async throws -> String {
        let system = """
        You are OmniPilot. Generate a concise end-of-day summary from today's conversations.
        Structure:
        - Key Discussions (2-3 bullet points)
        - Decisions Made (if any)
        - Action Items (if any)
        - People Mentioned (list)
        Keep it under 200 words. Be specific, not generic.
        """

        let allMemories = memories.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return try await generate(
            prompt: "Today's conversations:\n\n\(allMemories)\n\nGenerate daily summary:",
            system: system
        )
    }

    /// Check if Ollama is running
    func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    enum OllamaError: Error, LocalizedError {
        case requestFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .requestFailed: return "Ollama request failed. Is Ollama running?"
            case .invalidResponse: return "Invalid response from Ollama"
            }
        }
    }
}
