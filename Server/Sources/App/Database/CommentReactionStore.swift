import Foundation
import GRDB
import Vapor
import BudgetModels

/// Per-transaction comments (Honeydue chat) and emoji reactions.
struct CommentReactionStore {
    let db: DatabasePool

    // MARK: Comments

    func addComment(transactionID: UUID, memberID: UUID, body: String) async throws -> TransactionComment {
        let comment = TransactionComment(id: UUID(), transactionID: transactionID,
                                         memberID: memberID, body: body, createdAt: Date())
        try await db.write { db in
            try db.execute(sql: "INSERT INTO transaction_comments (id, transaction_id, member_id, body, created_at) VALUES (?,?,?,?,?)",
                           arguments: [comment.id.uuidString, transactionID.uuidString, memberID.uuidString,
                                       body, DBFormat.string(comment.createdAt)])
        }
        return comment
    }

    func comments(transactionID: UUID) async throws -> [TransactionComment] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transaction_comments WHERE transaction_id = ? ORDER BY created_at",
                             arguments: [transactionID.uuidString]).map(TransactionComment.init(row:))
        }
    }

    // MARK: Reactions

    /// Add a reaction (idempotent per member+emoji).
    func addReaction(transactionID: UUID, memberID: UUID, emoji: String) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO transaction_reactions (id, transaction_id, member_id, emoji, created_at)
                VALUES (?,?,?,?,?)
                ON CONFLICT(transaction_id, member_id, emoji) DO NOTHING
                """, arguments: [UUID().uuidString, transactionID.uuidString, memberID.uuidString,
                                 emoji, DBFormat.string(Date())])
        }
    }

    func removeReaction(transactionID: UUID, memberID: UUID, emoji: String) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM transaction_reactions WHERE transaction_id = ? AND member_id = ? AND emoji = ?",
                           arguments: [transactionID.uuidString, memberID.uuidString, emoji])
        }
    }

    func reactions(transactionID: UUID) async throws -> [TransactionReaction] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transaction_reactions WHERE transaction_id = ? ORDER BY created_at",
                             arguments: [transactionID.uuidString]).map(TransactionReaction.init(row:))
        }
    }

    // MARK: Activity feed

    /// Comments and reactions left by the *other* household members, newest
    /// first. Same visibility rule as `TransactionStore.list` — a private
    /// account (or a private transaction) hides its chatter from the partner
    /// too, otherwise the feed would leak the merchant name of a charge the
    /// transactions list carefully hides.
    ///
    /// One UNION query rather than two fetches merged in Swift: `LIMIT` has to
    /// apply to the combined, ordered stream, or a chatty week of comments
    /// would push every reaction off the page.
    func feed(householdID: UUID, memberID: UUID, since: Date?, limit: Int) async throws -> [ActivityEvent] {
        // Optional element type: `any DatabaseValueConvertible` doesn't
        // self-conform, so a non-optional array picks the failable
        // StatementArguments.init?([Any]) on Linux (see TransactionStore.list).
        var args: [(any DatabaseValueConvertible)?] = []

        func branch(_ kind: String, table: String, bodyColumn: String, emojiColumn: String) -> String {
            args.append(contentsOf: [householdID.uuidString, memberID.uuidString,
                                     memberID.uuidString, memberID.uuidString])
            var sql = """
                SELECT '\(kind)' AS kind, e.id AS id, e.created_at AS created_at,
                       e.member_id AS member_id, m.display_name AS display_name,
                       \(bodyColumn) AS body, \(emojiColumn) AS emoji,
                       t.id AS transaction_id, t.name AS transaction_name, t.amount AS amount
                FROM \(table) e
                JOIN transactions t ON t.id = e.transaction_id
                JOIN accounts a ON a.id = t.account_id
                LEFT JOIN memberships m ON m.id = e.member_id
                WHERE t.household_id = ?
                  AND e.member_id <> ?
                  AND (a.visibility = 'shared' OR a.owner_member_id = ?)
                  AND (t.visibility = 'shared' OR t.owner_member_id = ?)
                """
            if let since {
                sql += " AND e.created_at > ?"
                args.append(DBFormat.string(since))
            }
            return sql
        }

        var sql = branch("comment", table: "transaction_comments", bodyColumn: "e.body", emojiColumn: "NULL")
        sql += "\nUNION ALL\n"
        sql += branch("reaction", table: "transaction_reactions", bodyColumn: "NULL", emojiColumn: "e.emoji")
        // `id` breaks ties so two events written in the same second have a
        // stable order across pages.
        sql += "\nORDER BY created_at DESC, id DESC LIMIT ?"
        args.append(limit)

        let arguments = StatementArguments(args)
        return try await db.read { db in
            // Map inside the read: `Row` isn't Sendable.
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                ActivityEvent(
                    id: DBFormat.uuid(row["id"]) ?? UUID(),
                    kind: ActivityEvent.Kind(rawValue: row["kind"] as String? ?? "") ?? .comment,
                    createdAt: DBFormat.date(row["created_at"]) ?? Date(),
                    memberID: DBFormat.uuid(row["member_id"]) ?? UUID(),
                    memberName: (row["display_name"] as String?) ?? "Partner",
                    transactionID: DBFormat.uuid(row["transaction_id"]) ?? UUID(),
                    transactionName: (row["transaction_name"] as String?) ?? "",
                    transactionAmount: DBFormat.money(row["amount"]),
                    body: row["body"],
                    emoji: row["emoji"])
            }
        }
    }
}

extension Request {
    var activity: CommentReactionStore { CommentReactionStore(db: appDatabase.dbPool) }
}
