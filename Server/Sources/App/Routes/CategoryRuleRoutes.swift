import Vapor
import BudgetModels

/// Category rules. A rule is household-wide and applies to every future sync;
/// creating one also recategorizes existing matches — but only transactions
/// the caller can see, and never one a person categorized by hand.
func registerCategoryRuleRoutes(_ routes: RoutesBuilder) {
    let rules = routes.grouped(AuthMiddleware()).grouped("category-rules")

    rules.get { req async throws -> [CategoryRule] in
        let (household, _) = try await req.requireMembership()
        return try await req.categoryRules.list(householdID: household.id)
    }

    // GET /v1/category-rules/preview?transactionId= — how many others a rule
    // from this transaction's merchant would recategorize.
    rules.get("preview") { req async throws -> CategoryRulePreview in
        let (household, member) = try await req.requireMembership()
        guard let id = req.query[String.self, at: "transactionId"].flatMap(UUID.init(uuidString:)) else {
            throw Abort(.badRequest, reason: "transactionId is required")
        }
        let tx = try await visibleTransaction(req, id: id, householdID: household.id, memberID: member.id)
        let key = try merchantKey(of: tx)
        let count = try await req.categoryRules.matchCount(householdID: household.id, memberID: member.id,
                                                           key: key, excluding: tx.id)
        return CategoryRulePreview(merchantKey: key, matchCount: count)
    }

    // POST /v1/category-rules — rule from a transaction's merchant, applied now.
    rules.post { req async throws -> CreateCategoryRuleResponse in
        let (household, member) = try await req.requireMembership()
        let body = try req.content.decode(CreateCategoryRuleRequest.self)
        let tx = try await visibleTransaction(req, id: body.transactionID, householdID: household.id, memberID: member.id)
        let key = try merchantKey(of: tx)
        guard let category = try await req.categories.get(id: body.categoryID),
              category.householdID == household.id, !category.isArchived else {
            throw Abort(.notFound, reason: "Category not found")
        }
        return try await req.categoryRules.apply(householdID: household.id, memberID: member.id,
                                                 key: key, categoryID: category.id)
    }

    // DELETE /v1/category-rules/:id — stops future matches; past ones keep their category.
    rules.delete(":id") { req async throws -> HTTPStatus in
        let (household, _) = try await req.requireMembership()
        guard let id = req.parameters.get("id").flatMap(UUID.init(uuidString:)),
              try await req.categoryRules.householdID(ofRule: id) == household.id else {
            throw Abort(.notFound, reason: "Rule not found")
        }
        try await req.categoryRules.delete(id: id)
        return .noContent
    }
}

/// 404 — never 403 — for another household's or a hidden transaction.
private func visibleTransaction(_ req: Request, id: UUID, householdID: UUID, memberID: UUID) async throws -> Transaction {
    guard let tx = try await req.transactions.get(id: id), tx.householdID == householdID,
          try await req.transactions.isVisible(tx, to: memberID, accountStore: req.accounts) else {
        throw Abort(.notFound, reason: "Transaction not found")
    }
    return tx
}

private func merchantKey(of tx: Transaction) throws -> String {
    let key = CategoryRuleStore.merchantKey(merchantName: tx.merchantName, name: tx.name)
    guard !key.isEmpty else {
        throw Abort(.badRequest, reason: "This transaction has no merchant name to match on.")
    }
    return key
}
