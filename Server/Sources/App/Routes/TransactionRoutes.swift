import Vapor
import BudgetModels

/// Transactions list/detail, edits, and the couples activity layer (comments +
/// emoji reactions). Every route is scoped to the caller's household and honors
/// account + transaction visibility.
func registerTransactionRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())
    let txs = authed.grouped("transactions")

    // GET /v1/transactions?from=&to=&accountId=&categoryId=&search=&cursor=
    txs.get { req async throws -> TransactionPage in
        let (household, member) = try await req.requireMembership()
        let iso = ISO8601DateFormatter()
        var filter = TransactionStore.Filter()
        filter.from = req.query[String.self, at: "from"].flatMap(iso.date(from:))
        filter.to = req.query[String.self, at: "to"].flatMap(iso.date(from:))
        filter.accountID = req.query[String.self, at: "accountId"].flatMap { UUID(uuidString: $0) }
        filter.categoryID = req.query[String.self, at: "categoryId"].flatMap { UUID(uuidString: $0) }
        filter.search = req.query[String.self, at: "search"]
        filter.offset = req.query[String.self, at: "cursor"].flatMap { Int($0) } ?? 0
        return try await req.transactions.list(householdID: household.id, memberID: member.id, filter: filter)
    }

    // GET /v1/transactions/:id — detail with comments + reactions.
    txs.get(":id") { req async throws -> TransactionDetailResponse in
        let (tx, _) = try await loadVisible(req)
        async let comments = req.activity.comments(transactionID: tx.id)
        async let reactions = req.activity.reactions(transactionID: tx.id)
        return TransactionDetailResponse(transaction: tx, comments: try await comments, reactions: try await reactions)
    }

    // PATCH /v1/transactions/:id — recategorize / note / review / visibility / splits.
    txs.patch(":id") { req async throws -> Transaction in
        let (tx, member) = try await loadVisible(req)
        let body = try req.content.decode(UpdateTransactionRequest.self)
        // Only the owner may change a transaction's visibility.
        if body.visibility != nil && tx.ownerMemberID != member.id {
            throw Abort(.forbidden, reason: "Only the owner can change visibility.")
        }
        try await req.transactions.update(id: tx.id, body)
        return try await req.transactions.get(id: tx.id) ?? tx
    }

    // POST /v1/transactions/:id/comments
    txs.post(":id", "comments") { req async throws -> TransactionComment in
        let (tx, member) = try await loadVisible(req)
        let body = try req.content.decode(AddCommentRequest.self)
        let text = body.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Abort(.badRequest, reason: "Comment can't be empty.") }
        return try await req.activity.addComment(transactionID: tx.id, memberID: member.id, body: text)
    }

    // POST /v1/transactions/:id/reactions — toggle an emoji reaction for the member.
    txs.post(":id", "reactions") { req async throws -> [TransactionReaction] in
        let (tx, member) = try await loadVisible(req)
        let emoji = try req.content.decode(AddReactionRequest.self).emoji
        let existing = try await req.activity.reactions(transactionID: tx.id)
        if existing.contains(where: { $0.memberID == member.id && $0.emoji == emoji }) {
            try await req.activity.removeReaction(transactionID: tx.id, memberID: member.id, emoji: emoji)
        } else {
            try await req.activity.addReaction(transactionID: tx.id, memberID: member.id, emoji: emoji)
        }
        return try await req.activity.reactions(transactionID: tx.id)
    }
}

/// Loads the `:id` transaction, enforcing household scope + visibility.
private func loadVisible(_ req: Request) async throws -> (Transaction, HouseholdMember) {
    let (household, member) = try await req.requireMembership()
    guard let id = req.parameters.get("id").flatMap({ UUID(uuidString: $0) }) else {
        throw Abort(.badRequest, reason: "Invalid transaction id")
    }
    guard let tx = try await req.transactions.get(id: id), tx.householdID == household.id else {
        throw Abort(.notFound, reason: "Transaction not found")
    }
    guard try await req.transactions.isVisible(tx, to: member.id, accountStore: req.accounts) else {
        throw Abort(.notFound, reason: "Transaction not found")
    }
    return (tx, member)
}
