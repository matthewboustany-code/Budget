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
}

extension Request {
    var activity: CommentReactionStore { CommentReactionStore(db: appDatabase.dbPool) }
}
