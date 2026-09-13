import Foundation
import GRDB
import Vapor
import BudgetModels

/// A stored Plaid Item (one linked institution), with its access token
/// encrypted at rest.
struct PlaidItemRecord: Sendable {
    var id: UUID
    var householdID: UUID
    var ownerMemberID: UUID
    var plaidItemID: String
    var accessTokenEncrypted: String
    var institutionName: String?
    var transactionsCursor: String?
    var status: PlaidItemStatus = .ok
    var errorCode: String?
    var lastSyncedAt: Date?

    init(row: Row) {
        id = DBFormat.uuid(row["id"]) ?? UUID()
        householdID = DBFormat.uuid(row["household_id"]) ?? UUID()
        ownerMemberID = DBFormat.uuid(row["owner_member_id"]) ?? UUID()
        plaidItemID = row["plaid_item_id"]
        accessTokenEncrypted = row["access_token_encrypted"]
        institutionName = row["institution_name"]
        transactionsCursor = row["transactions_cursor"]
        status = (row["status"] as String?).flatMap(PlaidItemStatus.init(rawValue:)) ?? .ok
        errorCode = row["error_code"]
        lastSyncedAt = DBFormat.date(row["last_synced_at"])
    }

    init(id: UUID, householdID: UUID, ownerMemberID: UUID, plaidItemID: String,
         accessTokenEncrypted: String, institutionName: String?, transactionsCursor: String? = nil) {
        self.id = id
        self.householdID = householdID
        self.ownerMemberID = ownerMemberID
        self.plaidItemID = plaidItemID
        self.accessTokenEncrypted = accessTokenEncrypted
        self.institutionName = institutionName
        self.transactionsCursor = transactionsCursor
    }
}

struct PlaidItemStore {
    let db: DatabasePool

    func create(_ item: PlaidItemRecord) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO plaid_items (id, household_id, owner_member_id, plaid_item_id,
                    access_token_encrypted, institution_name, transactions_cursor, created_at)
                VALUES (?,?,?,?,?,?,?,?)
                """, arguments: [item.id.uuidString, item.householdID.uuidString, item.ownerMemberID.uuidString,
                                 item.plaidItemID, item.accessTokenEncrypted, item.institutionName,
                                 item.transactionsCursor, DBFormat.string(Date())])
        }
    }

    /// All items across all households (for the nightly sync command).
    func all() async throws -> [PlaidItemRecord] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM plaid_items").map(PlaidItemRecord.init(row:))
        }
    }

    func forHousehold(_ householdID: UUID) async throws -> [PlaidItemRecord] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM plaid_items WHERE household_id = ?",
                             arguments: [householdID.uuidString]).map(PlaidItemRecord.init(row:))
        }
    }

    func find(plaidItemID: String) async throws -> PlaidItemRecord? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM plaid_items WHERE plaid_item_id = ?",
                             arguments: [plaidItemID]).map(PlaidItemRecord.init(row:))
        }
    }

    /// Items owned by one member — the set to disconnect from Plaid when that
    /// person deletes their account.
    func forMember(_ memberID: UUID) async throws -> [PlaidItemRecord] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM plaid_items WHERE owner_member_id = ?",
                             arguments: [memberID.uuidString]).map(PlaidItemRecord.init(row:))
        }
    }

    func find(id: UUID) async throws -> PlaidItemRecord? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM plaid_items WHERE id = ?",
                             arguments: [id.uuidString]).map(PlaidItemRecord.init(row:))
        }
    }

    /// Deletes the row. `accounts` (and through them `transactions`) cascade.
    func delete(id: UUID) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM plaid_items WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// A sync succeeded: healthy again, error cleared, timestamp for the UI.
    func markSynced(id: UUID, at date: Date = Date()) async throws {
        try await db.write { db in
            try db.execute(sql: """
                UPDATE plaid_items SET status = 'ok', error_code = NULL, last_synced_at = ? WHERE id = ?
                """, arguments: [DBFormat.string(date), id.uuidString])
        }
    }

    /// Plaid says the connection is healthy (LOGIN_REPAIRED) without us
    /// having synced yet, so `last_synced_at` is left alone.
    func markHealthy(id: UUID) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE plaid_items SET status = 'ok', error_code = NULL WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    func markProblem(id: UUID, status: PlaidItemStatus, errorCode: String?, at date: Date = Date()) async throws {
        try await db.write { db in
            try db.execute(sql: """
                UPDATE plaid_items SET status = ?, error_code = ?, last_error_at = ? WHERE id = ?
                """, arguments: [status.rawValue, errorCode, DBFormat.string(date), id.uuidString])
        }
    }

    /// Plaid error codes that mean the *user* has to act (sign in again,
    /// re-grant access). Anything else — PRODUCT_NOT_READY on a fresh link,
    /// rate limits, an institution outage, a network blip — is transient and
    /// must not tell someone their bank is broken.
    static let userActionCodes: Set<String> = [
        "ITEM_LOGIN_REQUIRED", "INVALID_CREDENTIALS", "INSUFFICIENT_CREDENTIALS",
        "INVALID_MFA", "ITEM_LOCKED", "USER_SETUP_REQUIRED", "ACCESS_NOT_GRANTED",
        "NO_ACCOUNTS", "USER_PERMISSION_REVOKED",
    ]

    /// Marks the item as needing attention when a Plaid call failed for a
    /// reason only the owner can fix; leaves it alone otherwise.
    func recordFailure(id: UUID, _ error: Error) async throws {
        guard case PlaidError.api(_, let code?, _) = error, Self.userActionCodes.contains(code) else { return }
        try await markProblem(id: id, status: .error, errorCode: code)
    }

    func updateCursor(id: UUID, cursor: String) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE plaid_items SET transactions_cursor = ? WHERE id = ?",
                           arguments: [cursor, id.uuidString])
        }
    }
}

extension Request {
    var plaidItems: PlaidItemStore { PlaidItemStore(db: appDatabase.dbPool) }
}
