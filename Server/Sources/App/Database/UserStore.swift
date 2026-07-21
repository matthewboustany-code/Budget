import Foundation
import GRDB
import Vapor
import BudgetModels

/// Data access for users. Raw SQL over the GRDB pool (FlightBag's server style),
/// mapping rows to the shared `User` DTO.
struct UserStore {
    let db: DatabasePool

    func find(id: UUID) async throws -> User? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM users WHERE id = ?", arguments: [id.uuidString])
                .map(User.init(row:))
        }
    }

    func find(appleUserID: String) async throws -> User? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM users WHERE apple_user_id = ?", arguments: [appleUserID])
                .map(User.init(row:))
        }
    }

    /// Returns the existing user for this Apple subject, or creates one.
    func findOrCreate(appleUserID: String, email: String?, displayName: String) async throws -> User {
        if let existing = try await find(appleUserID: appleUserID) {
            return existing
        }
        let user = User(id: UUID(), appleUserID: appleUserID, email: email,
                        displayName: displayName, createdAt: Date())
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO users (id, apple_user_id, email, display_name, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [user.id.uuidString, user.appleUserID, user.email,
                            user.displayName, DBFormat.string(user.createdAt)])
        }
        return user
    }
}

extension Request {
    var users: UserStore { UserStore(db: appDatabase.dbPool) }
}
