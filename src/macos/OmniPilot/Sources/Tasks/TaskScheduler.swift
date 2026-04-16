import Foundation
import AppKit

/// Checks for due tasks every 30 seconds and executes them
class TaskScheduler: @unchecked Sendable {
    private let taskStore: TaskStore
    private var timer: Timer?
    private let checkInterval: TimeInterval = 30 // Check every 30 seconds

    /// Callback when a task is triggered (for UI updates)
    var onTaskTriggered: ((String, String) -> Void)?  // (action, description)

    init(taskStore: TaskStore) {
        self.taskStore = taskStore
    }

    /// Start the scheduler
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkDueTasks()
        }
        // Also check immediately
        checkDueTasks()
        print("[Scheduler] Started — checking every \(Int(checkInterval))s")
    }

    /// Stop the scheduler
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Check and execute due tasks
    private func checkDueTasks() {
        let dueTasks = taskStore.dueTasks()
        for task in dueTasks {
            executeTask(task)
        }
    }

    /// Execute a single due task
    private func executeTask(_ task: (id: Int64, action: String, description: String, message: String?, recipient: String?, phone: String?, scheduledAt: Date)) {

        print("[Scheduler] Executing task #\(task.id): \(task.description)")

        // Mark as triggered
        taskStore.markStatus(task.id, newStatus: "triggered")

        switch task.action {
        case "remind":
            // Level 1: Voice reminder + notification
            handleReminder(task)

        case "whatsapp":
            // Level 2: Open WhatsApp with pre-filled message
            handleWhatsApp(task)

        case "call":
            // Reminder to make a call
            handleCallReminder(task)

        case "email":
            // Open email compose
            handleEmail(task)

        default:
            handleReminder(task)
        }

        // Mark as done
        taskStore.markStatus(task.id, newStatus: "done")
        onTaskTriggered?(task.action, task.description)
    }

    // MARK: - Level 1: Reminders

    private func handleReminder(_ task: (id: Int64, action: String, description: String, message: String?, recipient: String?, phone: String?, scheduledAt: Date)) {
        // Speak the reminder aloud
        VoiceOutput.shared.speakReminder(task.description)

        // Show notification
        NotificationHelper.shared.send(
            title: "OmniPilot Reminder",
            body: task.description
        )
    }

    // MARK: - Level 2: WhatsApp

    private func handleWhatsApp(_ task: (id: Int64, action: String, description: String, message: String?, recipient: String?, phone: String?, scheduledAt: Date)) {
        // Speak what we're doing
        let recipientName = task.recipient ?? "the contact"
        VoiceOutput.shared.speak("Time to send a WhatsApp message to \(recipientName). Opening WhatsApp now.")

        // Notification
        NotificationHelper.shared.send(
            title: "OmniPilot — WhatsApp Message Ready",
            body: "To: \(recipientName)\nMessage: \(task.message ?? task.description)"
        )

        // Open WhatsApp with pre-filled message
        if let phone = task.phone, let message = task.message ?? Optional(task.description) {
            // WhatsApp URL scheme: https://api.whatsapp.com/send?phone=PHONE&text=MESSAGE
            let encodedMessage = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? message
            let cleanPhone = phone.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "+", with: "")

            // Try WhatsApp Desktop URL scheme first
            if let url = URL(string: "whatsapp://send?phone=\(cleanPhone)&text=\(encodedMessage)") {
                NSWorkspace.shared.open(url)
            }
            // Fallback to web WhatsApp
            else if let url = URL(string: "https://api.whatsapp.com/send?phone=\(cleanPhone)&text=\(encodedMessage)") {
                NSWorkspace.shared.open(url)
            }
        } else if let message = task.message {
            // No phone number — just open WhatsApp
            let encodedMessage = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? message
            if let url = URL(string: "whatsapp://send?text=\(encodedMessage)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Call Reminder

    private func handleCallReminder(_ task: (id: Int64, action: String, description: String, message: String?, recipient: String?, phone: String?, scheduledAt: Date)) {
        let recipientName = task.recipient ?? "the contact"
        VoiceOutput.shared.speakReminder("Time to call \(recipientName)")

        NotificationHelper.shared.send(
            title: "OmniPilot — Call Reminder",
            body: "Call \(recipientName)\(task.phone != nil ? " (\(task.phone!))" : "")"
        )

        // If phone number available, offer to initiate FaceTime audio
        if let phone = task.phone {
            if let url = URL(string: "tel:\(phone)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Email

    private func handleEmail(_ task: (id: Int64, action: String, description: String, message: String?, recipient: String?, phone: String?, scheduledAt: Date)) {
        VoiceOutput.shared.speak("Time to send an email. Opening your mail app.")

        NotificationHelper.shared.send(
            title: "OmniPilot — Email Reminder",
            body: "To: \(task.recipient ?? "?")\nSubject: \(task.description)"
        )

        // Open mailto link
        if let recipient = task.recipient {
            let subject = task.description.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let body = (task.message ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "mailto:\(recipient)?subject=\(subject)&body=\(body)") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
