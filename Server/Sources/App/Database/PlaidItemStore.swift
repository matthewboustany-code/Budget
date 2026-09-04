import Foundation
import GRDB
import Vapor

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

    init(row: Row) {
        id = DBFormat.uuid(row["id"]) ?? UUID()
        householdID = DBFormat.uuid(row["household_id"]) ?? UUID()
        ownerMemberID = DBFormat.uuid(row["owner_member_id"]) ?? UUID()
        plaidItemID = row["plaid_item_id"]
        accessTokenEncrypted = row["access_token_encrypted"]
        institutionName = row["institution_name"]
        transactionsCursor = row["transactions_cursor"]
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
