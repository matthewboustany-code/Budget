import Foundation
import Observation
import BudgetModels

/// Transactions list with search + pagination, and the per-transaction edit,
/// comment, and reaction calls.
@MainActor
@Observable
final class TransactionStore {
    private let api: APIClient

    /// What the list is narrowed to. Setting it doesn't load — the list view
    /// reloads when it differs from `loadedFilter`.
    struct Filter: Equatable {
        var accountID: UUID?
        var categoryID: UUID?
        var uncategorized = false
        var unreviewed = false
        var from: Date?
        var to: Date?

        static let needsReview = Filter(unreviewed: true)
        var isActive: Bool { self != Filter() }

        var queryItems: [URLQueryItem] {
            let iso = ISO8601DateFormatter()
            var items = [URLQueryItem]()
            if let accountID { items.append(.init(name: "accountId", value: accountID.uuidString)) }
            if uncategorized { items.append(.init(name: "uncategorized", value: "1")) }
            else if let categoryID { items.append(.init(name: "categoryId", value: categoryID.uuidString)) }
            if unreviewed { items.append(.init(name: "unreviewed", value: "1")) }
            if let from { items.append(.init(name: "from", value: iso.string(from: from))) }
            if let to { items.append(.init(name: "to", value: iso.string(from: to))) }
            return items
        }
    }

    var transactions: [Transaction] = []
    var filter = Filter()
    var reviewSummary: ReviewSummary?
    var isLoading = false
    var errorMessage: String?
    private(set) var nextCursor: String?
    private(set) var lastLoaded: Date?
    /// The filter the current `transactions` were fetched with.
    private(set) var loadedFilter: Filter?

    init(api: APIClient) {
        self.api = api
        // The unfiltered first page, as last seen; `load()` refreshes it.
        if let page: TransactionPage = api.cached("v1/transactions") {
            transactions = page.transactions
            nextCursor = page.nextCursor
            loadedFilter = Filter()
        }
        reviewSummary = api.cached("v1/transactions/review-summary")
    }

    var canLoadMore: Bool { nextCursor != nil }

    func load(search: String? = nil, reset: Bool = true) async {
        isLoading = true
        defer { isLoading = false }
        let requested = filter
        do {
            var query = requested.queryItems
            if let search, !search.isEmpty { query.append(.init(name: "search", value: search)) }
            let page: TransactionPage = try await api.get("v1/transactions", query: query)
            // A newer filter may have been set while this was in flight.
            guard requested == filter else { return }
            transactions = page.transactions
            nextCursor = page.nextCursor
            loadedFilter = requested
            errorMessage = nil
            lastLoaded = Date()
        } catch {
            errorMessage = friendly(error)
        }
        await loadReviewSummary()
    }

    func loadReviewSummary() async {
        do { reviewSummary = try await api.get("v1/transactions/review-summary") }
        catch { /* the dashboard row just stays as it was */ }
    }

    func loadMore(search: String? = nil) async {
        guard let cursor = nextCursor, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var query = filter.queryItems + [URLQueryItem(name: "cursor", value: cursor)]
            if let search, !search.isEmpty { query.append(.init(name: "search", value: search)) }
            let page: TransactionPage = try await api.get("v1/transactions", query: query)
            transactions.append(contentsOf: page.transactions)
            nextCursor = page.nextCursor
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Adds a transaction to a manual account, then reloads the first page.
    @discardableResult
    func addManual(_ request: CreateTransactionRequest) async -> Bool {
        do {
            let _: Transaction = try await api.post("v1/transactions", body: request)
            await load()
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    /// Deletes a manual-account transaction (the server refuses Plaid ones).
    @discardableResult
    func delete(_ tx: Transaction) async -> Bool {
        do {
            try await api.delete("v1/transactions/\(tx.id.uuidString)")
            transactions.removeAll { $0.id == tx.id }
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    func detail(_ id: UUID) async -> TransactionDetailResponse? {
        do { return try await api.get("v1/transactions/\(id.uuidString)") }
        catch { errorMessage = friendly(error); return nil }
    }

    @discardableResult
    func update(_ id: UUID, _ request: UpdateTransactionRequest) async -> Transaction? {
        do {
            let updated: Transaction = try await api.patch("v1/transactions/\(id.uuidString)", body: request)
            if let index = transactions.firstIndex(where: { $0.id == id }) { transactions[index] = updated }
            if request.isReviewed != nil || request.categoryID != nil || request.clearCategory != nil {
                await loadReviewSummary()
            }
            return updated
        } catch {
            errorMessage = friendly(error)
            return nil
        }
    }

    /// How many other transactions a rule from this one's merchant would move.
    func rulePreview(for id: UUID) async -> CategoryRulePreview? {
        try? await api.get("v1/category-rules/preview", query: [.init(name: "transactionId", value: id.uuidString)])
    }

    /// "Always file this merchant here": creates the rule, which also
    /// recategorizes past matches server-side, then reloads the list.
    @discardableResult
    func applyRule(transactionID: UUID, categoryID: UUID) async -> Int? {
        do {
            let response: CreateCategoryRuleResponse = try await api.post(
                "v1/category-rules", body: CreateCategoryRuleRequest(transactionID: transactionID, categoryID: categoryID))
            await load()
            return response.updatedCount
        } catch {
            errorMessage = friendly(error)
            return nil
        }
    }

    func addComment(_ id: UUID, body: String) async -> TransactionComment? {
        do { return try await api.post("v1/transactions/\(id.uuidString)/comments", body: AddCommentRequest(body: body)) }
        catch { errorMessage = friendly(error); return nil }
    }

    func toggleReaction(_ id: UUID, emoji: String) async -> [TransactionReaction]? {
        do { return try await api.post("v1/transactions/\(id.uuidString)/reactions", body: AddReactionRequest(emoji: emoji)) }
        catch { errorMessage = friendly(error); return nil }
    }

    private func friendly(_ error: Error) -> String {
        (error as? APIClientError)?.errorDescription ?? error.localizedDescription
    }
}
