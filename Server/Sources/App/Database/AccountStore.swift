import Foundation
import GRDB
import Vapor
import BudgetModels

/// Data access for accounts. List queries enforce per-account visibility (the
/// Honeydue model): a `.private` account is only returned to its owner.
struct AccountStore {
    let db: DatabasePool

    /// Accounts a member is allowed to see: shared ones, plus their own private.
    func visibleAccounts(householdID: UUID, memberID: UUID) async throws -> [Account] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM accounts
                WHERE household_id = ? AND (visibility = 'shared' OR owner_member_id = ?)
                ORDER BY is_hidden, type, name
                """, arguments: [householdID.uuidString, memberID.uuidString])
                .map(Account.init(row:))
        }
    }

    /// Every account in a household (used for the household's own net-worth
    /// snapshot, which counts private accounts too).
    func allAccounts(householdID: UUID) async throws -> [Account] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM accounts WHERE household_id = ?",
                             arguments: [householdID.uuidString]).map(Account.init(row:))
        }
    }

    func get(id: UUID) async throws -> Account? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [id.uuidString])
                .map(Account.init(row:))
        }
    }

    func update(id: UUID, name: String?, visibility: Visibility?, isHidden: Bool?) async throws {
        try await db.write { db in
            if let name {
                try db.execute(sql: "UPDATE accounts SET name = ? WHERE id = ?", arguments: [name, id.uuidString])
            }
            if let visibility {
                try db.execute(sql: "UPDATE accounts SET visibility = ? WHERE id = ?",
                               arguments: [visibility.rawValue, id.uuidString])
            }
            if let isHidden {
                try db.execute(sql: "UPDATE accounts SET is_hidden = ? WHERE id = ?",
                               arguments: [isHidden ? 1 : 0, id.uuidString])
            }
        }
    }

    /// Insert a freshly linked Plaid account, or update balances if we already
    /// have it (dedup by plaid_account_id).
    static func upsertPlaidAccount(_ a: Account, plaidItemID: UUID, _ db: Database) throws {
        if let pid = a.plaidAccountID,
           let existing = try Row.fetchOne(db, sql: "SELECT id FROM accounts WHERE plaid_account_id = ?",
                                           arguments: [pid]) {
            let existingID: String = existing["id"]
            try db.execute(sql: """
                UPDATE accounts SET current_balance = ?, available_balance = ?,
                    institution_name = ?, last_synced_at = ? WHERE id = ?
                """, arguments: [DBFormat.string(a.currentBalance),
                                 a.availableBalance.map(DBFormat.string),
                                 a.institutionName, DBFormat.string(a.lastSyncedAt ?? Date()), existingID])
        } else {
            try db.execute(sql: """
                INSERT INTO accounts (id, household_id, owner_member_id, plaid_item_id, plaid_account_id,
                    name, official_name, type, current_balance, available_balance, currency_code,
                    institution_name, mask, visibility, is_hidden, last_synced_at, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [a.id.uuidString, a.householdID.uuidString, a.ownerMemberID.uuidString,
                                 plaidItemID.uuidString, a.plaidAccountID, a.name, a.officialName,
                                 a.type.rawValue, DBFormat.string(a.currentBalance),
                                 a.availableBalance.map(DBFormat.string), a.currencyCode,
                                 a.institutionName, a.mask, a.visibility.rawValue, a.isHidden ? 1 : 0,
                                 DBFormat.string(a.lastSyncedAt ?? Date()), DBFormat.string(a.createdAt)])
        }
    }

    /// Update balances for an account by its Plaid id (nightly refresh).
    static func updateBalance(plaidAccountID: String, current: Money, available: Money?,
                              syncedAt: Date, _ db: Database) throws {
        try db.execute(sql: """
            UPDATE accounts SET current_balance = ?, available_balance = ?, last_synced_at = ?
            WHERE plaid_account_id = ?
            """, arguments: [DBFormat.string(current), available.map(DBFormat.string),
                             DBFormat.string(syncedAt), plaidAccountID])
    }
}

extension Request {
    var accounts: AccountStore { AccountStore(db: appDatabase.dbPool) }
}
