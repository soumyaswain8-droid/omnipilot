import Foundation

/// Parses natural language into structured task intents using Ollama
struct TaskIntent {
    let action: String       // "remind", "whatsapp", "email", "call"
    let description: String  // Human-readable description
    let message: String?     // Message content
    let recipient: String?   // Contact name
    let phone: String?       // Phone number (if mentioned)
    let scheduledAt: Date    // When to execute
}

class IntentParser {
    private let ollama: OllamaClient

    init(ollama: OllamaClient) {
        self.ollama = ollama
    }

    /// Parse a natural language command into a TaskIntent
    func parse(_ input: String) async throws -> TaskIntent? {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let nowStr = formatter.string(from: now)

        let calFormatter = DateFormatter()
        calFormatter.dateFormat = "EEEE"
        let dayOfWeek = calFormatter.string(from: now)

        let system = """
        You are a task parser. Extract structured data from the user's request.
        Current date/time: \(nowStr) (\(dayOfWeek))

        Return ONLY a JSON object with these fields:
        {
          "action": "remind" | "whatsapp" | "email" | "call",
          "description": "short description of the task",
          "message": "message content if sending a message, null otherwise",
          "recipient": "person's name if mentioned, null otherwise",
          "phone": "phone number if mentioned, null otherwise",
          "date": "YYYY-MM-DD",
          "time": "HH:MM"
        }

        Rules for date/time:
        - "tomorrow" = next day from \(nowStr)
        - "today" = current day
        - "in 30 minutes" = add 30 minutes to current time
        - "at 4 PM" = 16:00
        - "at 4" with no AM/PM = assume PM (16:00) for future times
        - "next Monday" = the coming Monday
        - "evening" = 18:00, "morning" = 09:00, "afternoon" = 14:00, "night" = 21:00

        Rules for action:
        - "remind me" / "remember to" / "don't forget" = "remind"
        - "send WhatsApp" / "message on WhatsApp" / "WhatsApp" = "whatsapp"
        - "send email" / "mail" / "email" = "email"
        - "call" / "phone" / "ring" = "call"
        - Default to "remind" if unclear

        Return ONLY the JSON. No explanation.
        """

        let response = try await ollama.generate(prompt: input, system: system)

        // Parse JSON from LLM response
        return parseJSON(response, now: now)
    }

    private func parseJSON(_ response: String, now: Date) -> TaskIntent? {
        // Extract JSON from response (LLM might wrap it in markdown)
        var jsonStr = response
        if let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}") {
            jsonStr = String(response[start...end])
        }

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[IntentParser] Failed to parse JSON: \(response)")
            return nil
        }

        let action = json["action"] as? String ?? "remind"
        let description = json["description"] as? String ?? ""
        let message = json["message"] as? String
        let recipient = json["recipient"] as? String
        let phone = json["phone"] as? String
        let dateStr = json["date"] as? String ?? ""
        let timeStr = json["time"] as? String ?? ""

        // Parse date + time
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let scheduledAt = formatter.date(from: "\(dateStr) \(timeStr)") ?? now.addingTimeInterval(3600)

        guard !description.isEmpty else { return nil }

        return TaskIntent(
            action: action,
            description: description,
            message: message,
            recipient: recipient,
            phone: phone,
            scheduledAt: scheduledAt
        )
    }

    /// Quick check if input looks like a task/reminder command
    static func looksLikeTask(_ input: String) -> Bool {
        let lower = input.lowercased()
        let keywords = [
            "remind me", "remember to", "don't forget", "dont forget",
            "send whatsapp", "send a whatsapp", "whatsapp message",
            "send email", "send an email", "email to",
            "call me", "call at", "schedule",
            "tomorrow", "at 4", "at 5", "at 6", "at 7", "at 8", "at 9",
            "in 30 minutes", "in an hour", "in 1 hour", "later today",
            "next week", "next monday", "next tuesday",
            "set a reminder", "set reminder"
        ]
        return keywords.contains(where: { lower.contains($0) })
    }
}
