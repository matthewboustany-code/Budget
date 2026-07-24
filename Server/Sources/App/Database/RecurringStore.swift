import Foundation
import GRDB
import Vapor
import BudgetModels
import BudgetKit

/// Stored recurring series (detected subscriptions/bills). Series are
/// household-wide rows, but listing joins accounts so a series drawn from a
/// private account is only returned to that account's owner — the same rule
/// transactions follow. Series with no account (shouldn't happen in practice)
/// stay visible to everyone.
struct RecurringStore {
    let db: DatabasePool

    func listVisible(householdID: UUID, memberID: UUID) async throws -> [RecurringSeries] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.* FROM recurring_series r
                LEFT JOIN accounts a ON a.id = r.account_id
                WHERE r.household_id = ?
                  AND (r.account_id IS NULL OR a.visibility = 'shared' OR a.owner_member_id = ?)
                ORDER BY r.next_date IS NULL, r.next_date, r.name
                """, arguments: [householdID.uuidString, memberID.uuidString])
                .map(RecurringSeries.init(row:))
        }
    }

    /// Every series regardless of account visibility — for operator commands
    /// (bill reminders), never for member-facing responses.
    func listAll(householdID: UUID) async throws -> [RecurringSeries] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM recurring_series WHERE household_id = ?
                ORDER BY next_date IS NULL, next_date, name
                """, arguments: [householdID.uuidString])
                .map(RecurringSeries.init(row:))
        }
    }

    func get(id: UUID) async throws -> RecurringSeries? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM recurring_series WHERE id = ?",
                             arguments: [id.uuidString])
                .map(RecurringSeries.init(row:))
        }
    }

    /// PATCH semantics: only non-nil fields are applied.
    func update(id: UUID, _ body: UpdateRecurringRequest) async throws {
        try await db.write { db in
            if let name = body.name {
                try db.execute(sql: "UPDATE recurring_series SET name = ? WHERE id = ?",
                               arguments: [name, id.uuidString])
            }
            if body.clearCategory == true {
                try db.execute(sql: "UPDATE recurring_series SET category_id = NULL WHERE id = ?",
                               arguments: [id.uuidString])
            } else if let categoryID = body.categoryID {
                try db.execute(sql: "UPDATE recurring_series SET category_id = ? WHERE id = ?",
                               arguments: [categoryID.uuidString, id.uuidString])
            }
            if let isActive = body.isActive {
                try db.execute(sql: "UPDATE recurring_series SET is_active = ? WHERE id = ?",
                               arguments: [isActive ? 1 : 0, id.uuidString])
            }
        }
    }

    /// Merge freshly detected series into storage, keyed by the immutable
    /// `merchant_key` (the normalized merchant name captured at insert). We
    /// deliberately do NOT key on `name`: the user owns the name (rename), and
    /// matching on it would orphan a renamed series and re-insert a duplicate
    /// under the merchant name on the next run. Detection owns the numbers
    /// (amount, cadence, dates, account); the user owns the words and the
    /// switch (name, category once set, and `isActive` — a series the user
    /// turned off never turns itself back on). Stored series the detector no
    /// longer reports are left alone.
    func mergeDetected(householdID: UUID, detected: [RecurringSeries]) async throws {
        try await db.write { db in
            struct Stored { let id: String; let categoryID: UUID?; let isActive: Bool }
            var existingByKey: [String: Stored] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT id, merchant_key, category_id, is_active FROM recurring_series WHERE household_id = ?",
                arguments: [householdID.uuidString]) {
                let key: String = row["merchant_key"] ?? ""
                // First row wins (a pre-fix duplicate can't resurrect itself).
                if existingByKey[key] == nil {
                    existingByKey[key] = Stored(id: row["id"],
                                                categoryID: DBFormat.uuid(row["category_id"]),
                                                isActive: DBFormat.bool(row["is_active"]))
                }
            }

            for series in detected {
                let key = RecurringDetector.normalize(series.name)
                if let stored = existingByKey[key] {
                    try db.execute(sql: """
                        UPDATE recurring_series
                        SET average_amount = ?, cadence = ?, account_id = ?,
                            last_date = ?, next_date = ?, category_id = ?, is_active = ?
                        WHERE id = ?
                        """, arguments: [
                            DBFormat.string(series.averageAmount), series.cadence.rawValue,
                            series.accountID?.uuidString,
                            series.lastDate.map(DBFormat.string), series.nextDate.map(DBFormat.string),
                            (stored.categoryID ?? series.categoryID)?.uuidString,
                            (stored.isActive && series.isActive) ? 1 : 0,
                            stored.id])
                } else {
                    try db.execute(sql: """
                        INSERT INTO recurring_series (id, household_id, merchant_key, name, category_id,
                            average_amount, cadence, account_id, last_date, next_date, is_active)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?)
                        """, arguments: [
                            series.id.uuidString, householdID.uuidString, key, series.name,
                            series.categoryID?.uuidString, DBFormat.string(series.averageAmount),
                            series.cadence.rawValue, series.accountID?.uuidString,
                            series.lastDate.map(DBFormat.string), series.nextDate.map(DBFormat.string),
                            series.isActive ? 1 : 0])
                }
            }
        }
    }
}

extension Request {
    var recurring: RecurringStore { RecurringStore(db: appDatabase.dbPool) }
}
