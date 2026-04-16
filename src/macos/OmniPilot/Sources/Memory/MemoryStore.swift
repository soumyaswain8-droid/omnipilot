import Foundation
import SQLite

/// Stores and retrieves memories using SQLite + FTS5
class MemoryStore {
    private var db: Connection?
    private let dbPath: String

    // Tables
    private let memories = Table("memories")
    private let id = SQLite.Expression<Int64>("id")
    private let timestamp = SQLite.Expression<Date>("timestamp")
    private let content = SQLite.Expression<String>("content")
    private let summary = SQLite.Expression<String?>("summary")
    private let source = SQLite.Expression<String>("source")
    private let memoryType = SQLite.Expression<String>("type")
    private let participants = SQLite.Expression<String?>("participants")
    private let topics = SQLite.Expression<String?>("topics")
    private let importanceScore = SQLite.Expression<Double>("importance_score")

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let omniDir = appSupport.appendingPathComponent("OmniPilot")
        try? FileManager.default.createDirectory(at: omniDir, withIntermediateDirectories: true)
        dbPath = omniDir.appendingPathComponent("memory.sqlite").path

        setupDatabase()
    }

    private func setupDatabase() {
        do {
            db = try Connection(dbPath)
            db?.busyTimeout = 5

            // Create memories table
            try db?.run(memories.create(ifNotExists: true) { t in
                t.column(id, primaryKey: .autoincrement)
                t.column(timestamp, defaultValue: Date())
                t.column(content)
                t.column(summary)
                t.column(source, defaultValue: "mic")
                t.column(memoryType, defaultValue: "transcription")
                t.column(participants)
                t.column(topics)
                t.column(importanceScore, defaultValue: 0.5)
            })

            // Create FTS5 virtual table for keyword search
            try db?.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts
                USING fts5(content, summary, participants, topics, content_rowid='id');
            """)

            print("[MemoryStore] Database ready at \(dbPath)")
            let count = try db?.scalar(memories.count) ?? 0
            print("[MemoryStore] \(count) memories stored")
        } catch {
            print("[MemoryStore] Setup error: \(error)")
        }
    }

    /// Store a new memory
    func store(text: String, source src: String = "mic", type: String = "transcription",
               participantList: [String]? = nil, topicList: [String]? = nil) -> Int64? {
        do {
            let rowId = try db?.run(memories.insert(
                content <- text,
                timestamp <- Date(),
                self.source <- src,
                memoryType <- type,
                participants <- participantList?.joined(separator: ", "),
                topics <- topicList?.joined(separator: ", ")
            ))

            // Update FTS index
            if let rowId = rowId {
                try db?.execute("""
                    INSERT INTO memories_fts(rowid, content, summary, participants, topics)
                    VALUES (\(rowId), '\(text.replacingOccurrences(of: "'", with: "''"))', NULL,
                            '\(participantList?.joined(separator: ", ") ?? "")',
                            '\(topicList?.joined(separator: ", ") ?? "")');
                """)
            }

            return rowId
        } catch {
            print("[MemoryStore] Insert error: \(error)")
            return nil
        }
    }

    /// Search memories using FTS5 keyword search
    func search(query: String, limit: Int = 10) -> [(id: Int64, content: String, timestamp: Date, score: Double)] {
        var results: [(Int64, String, Date, Double)] = []

        do {
            let safeQuery = query.replacingOccurrences(of: "'", with: "''")
            let rows = try db?.prepare("""
                SELECT m.id, m.content, m.timestamp, rank
                FROM memories_fts
                JOIN memories m ON memories_fts.rowid = m.id
                WHERE memories_fts MATCH '\(safeQuery)'
                ORDER BY rank
                LIMIT \(limit);
            """)

            if let rows = rows {
                for row in rows {
                    let id = row[0] as! Int64
                    let content = row[1] as! String
                    let ts = row[2] as! String
                    let score = row[3] as? Double ?? 0
                    let date = ISO8601DateFormatter().date(from: ts) ?? Date()
                    results.append((id, content, date, score))
                }
            }
        } catch {
            print("[MemoryStore] Search error: \(error)")
        }

        return results
    }

    /// Get recent memories
    func recent(limit: Int = 20) -> [(id: Int64, content: String, timestamp: Date)] {
        var results: [(Int64, String, Date)] = []

        do {
            let query = memories.order(timestamp.desc).limit(limit)
            for row in try db!.prepare(query) {
                results.append((row[id], row[content], row[timestamp]))
            }
        } catch {
            print("[MemoryStore] Recent query error: \(error)")
        }

        return results
    }

    /// Get today's memories for daily summary
    func todaysMemories() -> [(id: Int64, content: String, timestamp: Date)] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())

        var results: [(Int64, String, Date)] = []
        do {
            let query = memories
                .filter(timestamp >= startOfDay)
                .order(timestamp.asc)
            for row in try db!.prepare(query) {
                results.append((row[id], row[content], row[timestamp]))
            }
        } catch {
            print("[MemoryStore] Today query error: \(error)")
        }

        return results
    }

    /// Get total memory count
    func count() -> Int {
        return (try? db?.scalar(memories.count)) ?? 0
    }
}
