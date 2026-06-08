import Foundation
import SQLite

/// Local SQLite-backed durable queue for outbound relay events.
///
/// Why SQLite (not a file or in-memory queue):
///   • The PRD mandates "no message loss" across crashes, network outages,
///     and tunnel reconnects. A WAL-mode SQLite gives us that for free.
///   • IMsgCore already pulls in `SQLite.swift`, so this adds no new dep.
///   • We also use it for `cursor` (since_rowid) persistence so the watch
///     loop resumes exactly where it left off after a crash.
final class RelayQueue: @unchecked Sendable {
    struct PendingEvent: Sendable {
        let id: Int64
        let createdAt: Date
        let envelopeJSON: Data
        let attempts: Int
        let nextAttemptAt: Date
    }

    private let connection: Connection
    private let queue = DispatchQueue(label: "imsg-relay.queue", qos: .utility)

    init() throws {
        let dir = try RelayQueue.databaseDirectory()
        let path = dir.appendingPathComponent("relay.sqlite3").path
        connection = try Connection(path)
        connection.busyTimeout = 5
        try connection.execute("PRAGMA journal_mode = WAL;")
        try connection.execute("PRAGMA synchronous = NORMAL;")
        try migrate()
        Log.queue.info("RelayQueue ready at \(path, privacy: .public)")
    }

    // MARK: - Schema

    private func migrate() throws {
        try connection.execute(#"""
            CREATE TABLE IF NOT EXISTS events (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at      REAL    NOT NULL,
                envelope_json   BLOB    NOT NULL,
                attempts        INTEGER NOT NULL DEFAULT 0,
                next_attempt_at REAL    NOT NULL,
                state           TEXT    NOT NULL DEFAULT 'queued'
            );
            CREATE INDEX IF NOT EXISTS events_ready
                ON events(state, next_attempt_at);

            CREATE TABLE IF NOT EXISTS cursors (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
        """#)
    }

    // MARK: - Queue ops

    func enqueue(_ envelope: EventEnvelope) throws {
        let data = try JSONEncoder().encode(envelope)
        try queue.sync { () -> Void in
            try connection.run(
                "INSERT INTO events (created_at, envelope_json, next_attempt_at) VALUES (?, ?, ?)",
                Date().timeIntervalSince1970,
                Blob(bytes: Array(data)),
                Date().timeIntervalSince1970
            )
        }
    }

    /// Returns up to `limit` events whose `next_attempt_at` is in the past.
    /// Caller is responsible for either calling `markDelivered` or
    /// `markFailed` for every event returned.
    func dueEvents(limit: Int = 16) throws -> [PendingEvent] {
        try queue.sync {
            let now = Date().timeIntervalSince1970
            var out: [PendingEvent] = []
            let stmt = try connection.prepare(#"""
                SELECT id, created_at, envelope_json, attempts, next_attempt_at
                FROM events
                WHERE state = 'queued' AND next_attempt_at <= ?
                ORDER BY id ASC
                LIMIT ?
            """#, now, limit)
            for row in stmt {
                guard
                    let id = row[0] as? Int64,
                    let created = row[1] as? Double,
                    let blob = row[2] as? Blob,
                    let attempts = row[3] as? Int64,
                    let nextAttempt = row[4] as? Double
                else { continue }
                out.append(PendingEvent(
                    id: id,
                    createdAt: Date(timeIntervalSince1970: created),
                    envelopeJSON: Data(blob.bytes),
                    attempts: Int(attempts),
                    nextAttemptAt: Date(timeIntervalSince1970: nextAttempt)
                ))
            }
            return out
        }
    }

    func markDelivered(_ id: Int64) throws {
        try queue.sync { () -> Void in
            try connection.run("DELETE FROM events WHERE id = ?", id)
        }
    }

    /// Increments attempt count and pushes `next_attempt_at` out by an
    /// exponential backoff with jitter, capped at 60s. After
    /// `maxAttempts` the event is parked in state `dead` so it stops
    /// retrying but is still inspectable.
    func markFailed(_ id: Int64, attempts: Int, maxAttempts: Int) throws {
        let nextAttempts = attempts + 1
        if nextAttempts >= maxAttempts {
            try queue.sync { () -> Void in
                try connection.run("UPDATE events SET state = 'dead', attempts = ? WHERE id = ?",
                                   nextAttempts, id)
            }
            Log.queue.error("Event \(id, privacy: .public) parked as dead after \(nextAttempts) attempts")
            return
        }
        let base = min(60.0, pow(2.0, Double(nextAttempts)))
        let jitter = Double.random(in: 0...(base * 0.25))
        let next = Date().addingTimeInterval(base + jitter)
        try queue.sync { () -> Void in
            try connection.run(
                "UPDATE events SET attempts = ?, next_attempt_at = ? WHERE id = ?",
                nextAttempts, next.timeIntervalSince1970, id
            )
        }
    }

    func stats() -> (queued: Int, dead: Int) {
        queue.sync {
            let queued = (try? connection.scalar("SELECT COUNT(*) FROM events WHERE state = 'queued'") as? Int64) ?? 0
            let dead = (try? connection.scalar("SELECT COUNT(*) FROM events WHERE state = 'dead'") as? Int64) ?? 0
            return (Int(queued), Int(dead))
        }
    }

    /// Drop everything in the `dead` state. Useful when the user just
    /// finished configuring an endpoint and wants a clean slate without
    /// reaching for `sqlite3` on the command line.
    @discardableResult
    func clearDead() -> Int {
        queue.sync {
            do {
                let before = (try? connection.scalar("SELECT COUNT(*) FROM events WHERE state = 'dead'") as? Int64) ?? 0
                try connection.run("DELETE FROM events WHERE state = 'dead'")
                Log.queue.info("Cleared \(before, privacy: .public) dead events")
                return Int(before)
            } catch {
                Log.queue.error("Failed to clear dead events: \(error.localizedDescription, privacy: .public)")
                return 0
            }
        }
    }

    // MARK: - Cursors

    func cursor(_ key: String) -> String? {
        try? queue.sync {
            try connection.scalar("SELECT value FROM cursors WHERE key = ?", key) as? String
        }
    }

    func setCursor(_ key: String, _ value: String) {
        do {
            try queue.sync { () -> Void in
                try connection.run(
                    "INSERT INTO cursors(key, value) VALUES(?, ?) " +
                    "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    key, value
                )
            }
        } catch {
            Log.queue.error("Failed to persist cursor \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static func databaseDirectory() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("imsg-relay", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
