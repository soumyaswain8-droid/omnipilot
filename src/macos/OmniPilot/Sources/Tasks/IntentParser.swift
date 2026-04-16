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
        // First try fast local parsing (no LLM needed for simple patterns)
        if let quickResult = quickParse(input) {
            return quickResult
        }

        // Fall back to LLM for complex requests
        return try await llmParse(input)
    }

    // MARK: - Fast Local Parsing (no LLM, instant)

    private func quickParse(_ input: String) -> TaskIntent? {
        let lower = input.lowercased()
        let now = Date()

        // Extract time
        guard let scheduledDate = extractTime(from: lower, relativeTo: now) else {
            return nil
        }

        // Determine action
        let action: String
        if lower.contains("whatsapp") || lower.contains("message") {
            action = "whatsapp"
        } else if lower.contains("email") || lower.contains("mail") {
            action = "email"
        } else if lower.contains("call") || lower.contains("phone") || lower.contains("ring") {
            action = "call"
        } else {
            action = "remind"
        }

        // Extract recipient (after "to" or "with")
        let recipient = extractRecipient(from: input)

        // Extract message content (after "saying" or "that" or "message")
        let message = extractMessage(from: input)

        // Build description
        let desc = buildDescription(from: input)

        return TaskIntent(
            action: action,
            description: desc,
            message: message,
            recipient: recipient,
            phone: nil,
            scheduledAt: scheduledDate
        )
    }

    private func extractTime(from input: String, relativeTo now: Date) -> Date? {
        let calendar = Calendar.current

        // "in X minutes/hours" or "after X minutes/hours"
        let minPatterns = [#"(?:in|after) (\d+) min"#, #"(\d+) minutes? (?:from now|later)"#]
        for pattern in minPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
               let range = Range(match.range(at: 1), in: input),
               let mins = Int(input[range]) {
                return now.addingTimeInterval(Double(mins) * 60)
            }
        }

        let hrPatterns = [#"(?:in|after) (\d+) hour"#, #"(\d+) hours? (?:from now|later)"#]
        for pattern in hrPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
               let range = Range(match.range(at: 1), in: input),
               let hrs = Int(input[range]) {
                return now.addingTimeInterval(Double(hrs) * 3600)
            }
        }

        if input.contains("in half an hour") || input.contains("in 30 min") || input.contains("after half an hour") {
            return now.addingTimeInterval(1800)
        }

        // Determine base date
        var baseDate = now
        if input.contains("tomorrow") {
            baseDate = calendar.date(byAdding: .day, value: 1, to: now)!
        } else if input.contains("day after") || input.contains("day after tomorrow") {
            baseDate = calendar.date(byAdding: .day, value: 2, to: now)!
        } else if input.contains("next week") {
            baseDate = calendar.date(byAdding: .day, value: 7, to: now)!
        }

        // Extract hour — "at X PM/AM" or "at XX:XX"
        if let match = input.range(of: #"at (\d{1,2})\s*(pm|am|PM|AM)"#, options: .regularExpression) {
            let timeStr = String(input[match])
            let parts = timeStr.replacingOccurrences(of: "at ", with: "")
            let isPM = parts.lowercased().contains("pm")
            let hourStr = parts.replacingOccurrences(of: #"\s*(pm|am|PM|AM)"#, with: "", options: .regularExpression)
            if var hour = Int(hourStr) {
                if isPM && hour < 12 { hour += 12 }
                if !isPM && hour == 12 { hour = 0 }
                var comps = calendar.dateComponents([.year, .month, .day], from: baseDate)
                comps.hour = hour
                comps.minute = 0
                return calendar.date(from: comps)
            }
        }

        // "at X" without AM/PM — assume PM for 1-9, AM for 10-11
        if let match = input.range(of: #"at (\d{1,2})($|\s|,|\.)"#, options: .regularExpression) {
            let numStr = String(input[match]).replacingOccurrences(of: "at ", with: "").trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            if var hour = Int(numStr) {
                if hour >= 1 && hour <= 9 { hour += 12 } // assume PM
                var comps = calendar.dateComponents([.year, .month, .day], from: baseDate)
                comps.hour = hour
                comps.minute = 0
                return calendar.date(from: comps)
            }
        }

        // Time words
        if input.contains("morning") {
            var comps = calendar.dateComponents([.year, .month, .day], from: baseDate)
            comps.hour = 9; comps.minute = 0
            return calendar.date(from: comps)
        }
        if input.contains("afternoon") {
            var comps = calendar.dateComponents([.year, .month, .day], from: baseDate)
            comps.hour = 14; comps.minute = 0
            return calendar.date(from: comps)
        }
        if input.contains("evening") {
            var comps = calendar.dateComponents([.year, .month, .day], from: baseDate)
            comps.hour = 18; comps.minute = 0
            return calendar.date(from: comps)
        }
        if input.contains("night") {
            var comps = calendar.dateComponents([.year, .month, .day], from: baseDate)
            comps.hour = 21; comps.minute = 0
            return calendar.date(from: comps)
        }

        // If we have a base date but no specific time, default to 9 AM
        if baseDate != now {
            var comps = calendar.dateComponents([.year, .month, .day], from: baseDate)
            comps.hour = 9; comps.minute = 0
            return calendar.date(from: comps)
        }

        return nil
    }

    private func extractRecipient(from input: String) -> String? {
        // Look for patterns: "to NAME", "with NAME", "call NAME"
        let patterns = [
            #"(?:to|with|call)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) {
                if let range = Range(match.range(at: 1), in: input) {
                    let name = String(input[range])
                    // Filter out common words that aren't names
                    let notNames = ["the", "my", "a", "an", "this", "that", "do", "take", "send"]
                    if !notNames.contains(name.lowercased()) {
                        return name
                    }
                }
            }
        }
        return nil
    }

    private func extractMessage(from input: String) -> String? {
        // Look for "saying ...", "that ...", "message ..."
        let triggers = ["saying ", "that says ", "message ", "saying that "]
        for trigger in triggers {
            if let range = input.lowercased().range(of: trigger) {
                let afterTrigger = input[range.upperBound...]
                let msg = String(afterTrigger).trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty { return msg }
            }
        }
        return nil
    }

    private func buildDescription(from input: String) -> String {
        // Clean up the input to make a short description
        var desc = input
        // Remove time references
        let removePatterns = [
            #"(tomorrow|today|tonight|next week|in \d+ (minutes?|hours?))"#,
            #"at \d{1,2}\s*(pm|am|PM|AM)?"#,
            #"(morning|afternoon|evening|night)"#,
            #"(remind me to|remember to|don't forget to|set a reminder to)"#,
            #"(send (a )?whatsapp to|send (a )?message to|send (an )?email to)"#,
        ]
        for pattern in removePatterns {
            desc = desc.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        desc = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        // Capitalize first letter
        if let first = desc.first {
            desc = first.uppercased() + desc.dropFirst()
        }
        return desc.isEmpty ? input : desc
    }

    // MARK: - LLM Parsing (slow, for complex requests)

    private func llmParse(_ input: String) async throws -> TaskIntent? {
        // Use quick parse as fallback — LLM is too slow for interactive use
        // For v0.3, we rely on the fast local parser
        // LLM parsing can be added later with a faster model
        return nil
    }

    /// Quick check if input looks like a task/reminder command
    static func looksLikeTask(_ input: String) -> Bool {
        let lower = input.lowercased()
        let keywords = [
            "remind me", "remember to", "don't forget", "dont forget",
            "send whatsapp", "send a whatsapp", "whatsapp message",
            "send email", "send an email", "email to",
            "call me", "schedule",
            "in 30 min", "in an hour", "in 1 hour",
            "after 5 min", "after 10 min", "after 30 min",
            "after 1 hour", "after 2 hour",
            "set a reminder", "set reminder",
            "tomorrow at", "today at", "at 4 pm", "at 5 pm",
            "at 6 pm", "at 7 pm", "at 8 pm", "at 9 pm",
            "at 10 am", "at 11 am", "this evening", "tonight",
        ]
        return keywords.contains(where: { lower.contains($0) })
    }
}
