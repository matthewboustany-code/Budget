import Foundation
import GRDB
import Vapor
import BudgetModels

/// Data access for transactions. Listing joins accounts so a transaction is
/// only returned when BOTH its account and the transaction itself are visible
/// to the member (a private account hides all its transactions).
struct TransactionStore {
    let db: DatabasePool

    struct Filter {
        var from: Date?
        var to: Date?
        var accountID: UUID?
        var categoryID: UUID?
        var search: String?
        var offset: Int = 0
        var limit: Int = 50
    }

    func list(householdID: UUID, memberID: UUID, filter: Filter) async throws -> TransactionPage {
        var sql = """
            SELECT t.* FROM transactions t
            JOIN accounts a ON a.id = t.account_id
            WHERE t.household_id = ?
              AND (a.visibility = 'shared' OR a.owner_member_id = ?)
              AND (t.visibility = 'shared' OR t.owner_member_id = ?)
            """
        var args: [any DatabaseValueConvertible] = [householdID.uuidString, memberID.uuidString, memberID.uuidString]
        if let from = filter.from { sql += " AND t.date >= ?"; args.append(DBFormat.string(from)) }
        if let to = filter.to { sql += " AND t.date <= ?"; args.append(DBFormat.string(to)) }
        if let accountID = filter.accountID { sql += " AND t.account_id = ?"; args.append(accountID.uuidString) }
        if let categoryID = filter.categoryID { sql += " AND t.category_id = ?"; args.append(categoryID.uuidString) }
        if let search = filter.search, !search.isEmpty {
            sql += " AND (t.name LIKE ? OR t.merchant_name LIKE ?)"
            args.append("%\(search)%"); args.append("%\(search)%")
        }
        sql += " ORDER BY t.date DESC, t.created_at DESC LIMIT ? OFFSET ?"
        args.append(filter.limit + 1)   // fetch one extra to detect another page
        args.append(filter.offset)

        let rows = try await db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
        var transactions = rows.map(Transaction.init(row:))
        var nextCursor: String?
        if transactions.count > filter.limit {
            transactions.removeLast()
            nextCursor = String(filter.offset + filter.limit)
        }
        return TransactionPage(transactions: transactions, nextCursor: nextCursor)
    }

    func get(id: UUID) async throws -> Transaction? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM transactions WHERE id = ?", arguments: [id.uuidString])
                .map(Transaction.init(row:))
        }
    }

    /// Whether the member is allowed to see this transaction (account + tx visibility).
    func isVisible(_ tx: Transaction, to memberID: UUID, accountStore: AccountStore) async throws -> Bool {
        if tx.visibility == .private && tx.ownerMemberID != memberID { return false }
        guard let account = try await accountStore.get(id: tx.accountID) else { return false }
        if account.visibility == .private && account.ownerMemberID != memberID { return false }
        return true
    }

    func update(id: UUID, _ body: UpdateTransactionRequest) async throws {
        try await db.write { db in
            if body.clearCategory == true {
                try db.execute(sql: "UPDATE transactions SET category_id = NULL WHERE id = ?", arguments: [id.uuidString])
            } else if let categoryID = body.categoryID {
                try db.execute(sql: "UPDATE transactions SET category_id = ? WHERE id = ?",
                               arguments: [categoryID.uuidString, id.uuidString])
            }
            if let note = body.note {
                try db.execute(sql: "UPDATE transactions SET note = ? WHERE id = ?",
                               arguments: [note.isEmpty ? nil : note, id.uuidString])
            }
            if let reviewed = body.isReviewed {
                try db.execute(sql: "UPDATE transactions SET is_reviewed = ? WHERE id = ?",
                               arguments: [reviewed ? 1 : 0, id.uuidString])
            }
            if let visibility = body.visibility {
                try db.execute(sql: "UPDATE transactions SET visibility = ? WHERE id = ?",
                               arguments: [visibility.rawValue, id.uuidString])
            }
            if let splits = body.splits {
                let json = splits.isEmpty ? nil : String(data: try JSONEncoder().encode(splits), encoding: .utf8)
                try db.execute(sql: "UPDATE transactions SET splits_json = ? WHERE id = ?",
                               arguments: [json, id.uuidString])
            }
        }
    }

    /// Insert a Plaid transaction, or update only Plaid-owned fields if it exists
    /// (so user edits — category, note, reviewed, visibility — are preserved).
    static func upsertPlaid(_ tx: Transaction, _ db: Database) throws {
        guard let plaidID = tx.plaidTransactionID else { return }
        if let existing = try Row.fetchOne(db, sql: "SELECT id FROM transactions WHERE plaid_transaction_id = ?",
                                           arguments: [plaidID]) {
            let id: String = existing["id"]
            try db.execute(sql: """
                UPDATE transactions SET amount = ?, date = ?, name = ?, merchant_name = ?, status = ?
                WHERE id = ?
                """, arguments: [DBFormat.string(tx.amount), DBFormat.string(tx.date), tx.name,
                                 tx.merchantName, tx.status.rawValue, id])
        } else {
            try db.execute(sql: """
                INSERT INTO transactions (id, household_id, account_id, owner_member_id, amount, date,
                    name, merchant_name, category_id, status, note, is_reviewed, visibility, splits_json,
                    plaid_transaction_id, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [tx.id.uuidString, tx.householdID.uuidString, tx.accountID.uuidString,
                                 tx.ownerMemberID.uuidString, DBFormat.string(tx.amount), DBFormat.string(tx.date),
                                 tx.name, tx.merchantName, tx.categoryID?.uuidString, tx.status.rawValue,
                                 tx.note, tx.isReviewed ? 1 : 0, tx.visibility.rawValue, nil, plaidID,
                                 DBFormat.string(tx.createdAt)])
        }
    }
}

extension Request {
    var transactions: TransactionStore { TransactionStore(db: appDatabase.dbPool) }
}
