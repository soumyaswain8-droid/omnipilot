import Foundation
import SQLite

/// Stores scheduled tasks and reminders
class TaskStore {
    private let db: Connection
    private let tasks = Table("scheduled_tasks")

    // Columns
    private let id = SQLite.Expression<Int64>("id")
    private let action = SQLite.Expression<String>("action")           // "remind", "whatsapp", "email", "call"
    private let description = SQLite.Expression<String>("description") // Human-readable: "Send report to Kishore"
    private let message = SQLite.Expression<String?>("message")        // Message content (for whatsapp/email)
    private let recipient = SQLite.Expression<String?>("recipient")    // Contact name
    private let phone = SQLite.Expression<String?>("phone")            // Phone number
    private let scheduledAt = SQLite.Expression<Date>("scheduled_at")  // When to execute
    private let createdAt = SQLite.Expression<Date>("created_at")
    private let status = SQLite.Expression<String>("status")           // "pending", "triggered", "done", "cancelled"
    private let spokenConfirmation = SQLite.Expression<String?>("spoken_confirmation") // What OmniPilot said when created

    init(db: Connection) {
        self.db = db
        setupTable()
    }

    private func setupTable() {
        do {
            try db.run(tasks.create(ifNotExists: true) { t in
                t.column(id, primaryKey: .autoincrement)
                t.column(action, defaultValue: "remind")
                t.column(description)
                t.column(message)
                t.column(recipient)
                t.column(phone)
                t.column(scheduledAt)
                t.column(createdAt, defaultValue: Date())
                t.column(status, defaultValue: "pending")
                t.column(spokenConfirmation)
            })
        } catch {
            print("[TaskStore] Setup error: \(error)")
        }
    }

    /// Create a new scheduled task
    @discardableResult
    func create(
        actionType: String,
        desc: String,
        msg: String? = nil,
        recipientName: String? = nil,
        phoneNumber: String? = nil,
        scheduleDate: Date,
        confirmation: String? = nil
    ) -> Int64? {
        do {
            let rowId = try db.run(tasks.insert(
                action <- actionType,
                description <- desc,
                message <- msg,
                recipient <- recipientName,
                phone <- phoneNumber,
                scheduledAt <- scheduleDate,
                createdAt <- Date(),
                status <- "pending",
                spokenConfirmation <- confirmation
            ))
            print("[TaskStore] Created task #\(rowId): \(desc) at \(scheduleDate)")
            return rowId
        } catch {
            print("[TaskStore] Insert error: \(error)")
            return nil
        }
    }

    /// Get all pending tasks that are due (scheduled_at <= now)
    func dueTasks() -> [(id: Int64, action: String, description: String, message: String?, recipient: String?, phone: String?, scheduledAt: Date)] {
        var results: [(Int64, String, String, String?, String?, String?, Date)] = []
        do {
            let query = tasks
                .filter(status == "pending")
                .filter(scheduledAt <= Date())
                .order(scheduledAt.asc)
            for row in try db.prepare(query) {
                results.append((
                    row[id], row[action], row[description],
                    row[message], row[recipient], row[phone], row[scheduledAt]
                ))
            }
        } catch {
            print("[TaskStore] Query error: \(error)")
        }
        return results
    }

    /// Get all pending future tasks
    func pendingTasks() -> [(id: Int64, action: String, description: String, recipient: String?, scheduledAt: Date)] {
        var results: [(Int64, String, String, String?, Date)] = []
        do {
            let query = tasks
                .filter(status == "pending")
                .order(scheduledAt.asc)
            for row in try db.prepare(query) {
                results.append((row[id], row[action], row[description], row[recipient], row[scheduledAt]))
            }
        } catch {
            print("[TaskStore] Query error: \(error)")
        }
        return results
    }

    /// Mark task as triggered/done
    func markStatus(_ taskId: Int64, newStatus: String) {
        do {
            try db.run(tasks.filter(id == taskId).update(status <- newStatus))
        } catch {
            print("[TaskStore] Update error: \(error)")
        }
    }

    /// Count pending tasks
    func pendingCount() -> Int {
        return (try? db.scalar(tasks.filter(status == "pending").count)) ?? 0
    }

    /// Get recent tasks (for UI)
    func recentTasks(limit: Int = 20) -> [(id: Int64, action: String, description: String, status: String, scheduledAt: Date)] {
        var results: [(Int64, String, String, String, Date)] = []
        do {
            let query = tasks.order(scheduledAt.desc).limit(limit)
            for row in try db.prepare(query) {
                results.append((row[id], row[action], row[description], row[status], row[scheduledAt]))
            }
        } catch {
            print("[TaskStore] Query error: \(error)")
        }
        return results
    }

    /// Cancel a task
    func cancel(_ taskId: Int64) {
        markStatus(taskId, newStatus: "cancelled")
    }
}
