import Foundation
import GRDB
import Vapor
import BudgetModels

/// Monthly category budgets. Storage only — the budget-vs-actual math lives in
/// `BudgetKit.BudgetCalculator` so app and server can never disagree.
struct BudgetStore {
    let db: DatabasePool

    /// Every budget the household has ever set, across all months. The rollover
    /// walk needs prior months, and at personal scale (a couple, one row per
    /// budgeted category per month) the whole table is trivially small.
    func listAll(householdID: UUID) async throws -> [Budget] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM budgets WHERE household_id = ?",
                             arguments: [householdID.uuidString]).map(Budget.init(row:))
        }
    }

    /// The earliest month any rollover chain could reach back to: every chain
    /// starts at a rollover-enabled budget, so no rollup needs transactions
    /// before this. Nil when rollover was never switched on.
    func earliestRolloverMonth(householdID: UUID) async throws -> Month? {
        try await db.read { db in
            try String.fetchOne(db, sql: """
                SELECT MIN(month) FROM budgets WHERE household_id = ? AND rollover_enabled = 1
                """, arguments: [householdID.uuidString]).flatMap(Month.init)
        }
    }

    /// Insert-or-replace the budget for one category+month (the
    /// `UNIQUE(category_id, month)` pair), returning the stored row.
    func upsert(householdID: UUID, categoryID: UUID, month: Month,
                amount: Money, rolloverEnabled: Bool) async throws -> Budget {
        try await db.write { db in
            let existing = try Row.fetchOne(
                db, sql: "SELECT id FROM budgets WHERE category_id = ? AND month = ?",
                arguments: [categoryID.uuidString, month.description])
            let id = existing.flatMap { DBFormat.uuid($0["id"]) } ?? UUID()
            try db.execute(sql: """
                INSERT INTO budgets (id, household_id, category_id, month, amount, rollover_enabled)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(category_id, month) DO UPDATE SET amount = excluded.amount,
                    rollover_enabled = excluded.rollover_enabled
                """, arguments: [id.uuidString, householdID.uuidString, categoryID.uuidString,
                                 month.description, DBFormat.string(amount), rolloverEnabled ? 1 : 0])
            return Budget(id: id, householdID: householdID, categoryID: categoryID,
                          month: month, amount: amount, rolloverEnabled: rolloverEnabled)
        }
    }
}

extension Request {
    var budgets: BudgetStore { BudgetStore(db: appDatabase.dbPool) }
}
