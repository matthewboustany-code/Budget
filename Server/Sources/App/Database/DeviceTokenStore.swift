import Foundation
import GRDB
import Vapor

/// One registered APNs device token. `environment` records which APNs host the
/// token was minted against — a sandbox token is rejected by the production
/// host and vice versa, so it's stored rather than inferred at send time.
struct DeviceToken: Sendable {
    var token: String
    var userID: UUID
    var environment: String
    var updatedAt: Date
}

struct DeviceTokenStore {
    let db: DatabasePool

    /// Upsert: the same device re-registering (every launch) must not create a
    /// second row, and a token that moves to another user follows that user.
    func register(token: String, userID: UUID, environment: String) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO device_tokens (token, user_id, environment, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(token) DO UPDATE SET
                    user_id = excluded.user_id,
                    environment = excluded.environment,
                    updated_at = excluded.updated_at
                """,
                arguments: [token, userID.uuidString, environment, DBFormat.string(Date())])
        }
    }

    func unregister(token: String) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM device_tokens WHERE token = ?", arguments: [token])
        }
    }

    func tokens(userIDs: [UUID]) async throws -> [DeviceToken] {
        guard !userIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: userIDs.count).joined(separator: ",")
        let args = StatementArguments(userIDs.map { $0.uuidString })
        return try await db.read { db in
            // Map inside the read: GRDB `Row` isn't Sendable and must not cross
            // the async boundary (see the other stores).
            try Row.fetchAll(db,
                sql: "SELECT * FROM device_tokens WHERE user_id IN (\(placeholders))",
                arguments: args
            ).map { row in
                DeviceToken(token: row["token"],
                            userID: UUID(uuidString: row["user_id"]) ?? UUID(),
                            environment: row["environment"],
                            updatedAt: DBFormat.date(row["updated_at"]) ?? Date())
            }
        }
    }
}

extension Request {
    var deviceTokens: DeviceTokenStore { DeviceTokenStore(db: appDatabase.dbPool) }
}
