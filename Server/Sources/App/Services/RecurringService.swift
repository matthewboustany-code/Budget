import Foundation
import GRDB
import Vapor
import BudgetModels
import BudgetKit

/// Runs `RecurringDetector` over a household's history and merges the result
/// into `recurring_series` (see `RecurringStore.mergeDetected` for what the
/// user owns vs. what detection owns). Runs after every transaction sync and
/// on demand via `POST /v1/recurring/refresh`.
///
/// Detection input deliberately excludes transactions the owner marked
/// private: a household-wide series must never surface amounts the partner
/// can't see. Series drawn from a *private account* are detected normally —
/// the read path hides those from the partner wholesale.
struct RecurringService {
    let db: DatabasePool

    /// How far back detection looks. 24 months, not 12: a yearly series needs
    /// three charges (`RecurringDetector.minimumOccurrences`), so this is the
    /// floor that still sees one — anything shorter silently drops yearly bills.
    static let lookbackMonths = 24

    func refresh(householdID: UUID, now: Date = Date()) async throws {
        let since = Calendar.current.date(byAdding: .month, value: -Self.lookbackMonths, to: now) ?? now
        let transactions = try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM transactions
                WHERE household_id = ? AND visibility = 'shared' AND date >= ?
                """, arguments: [householdID.uuidString, DBFormat.string(since)])
                .map(Transaction.init(row:))
        }
        let detected = RecurringDetector.detect(transactions: transactions,
                                                householdID: householdID)
        try await RecurringStore(db: db).mergeDetected(householdID: householdID,
                                                       detected: detected)
    }
}

extension Request {
    var recurringService: RecurringService { RecurringService(db: appDatabase.dbPool) }
}
