import Foundation
import Observation
import BudgetModels

/// Transactions list with search + pagination, and the per-transaction edit,
/// comment, and reaction calls.
@MainActor
@Observable
final class TransactionStore {
    private let api: APIClient

    var transactions: [Transaction] = []
    var isLoading = false
    var errorMessage: String?
    private(set) var nextCursor: String?
    private(set) var lastLoaded: Date?

    init(api: APIClient) {
        self.api = api
        // The unfiltered first page, as last seen; `load()` refreshes it.
        if let page: TransactionPage = api.cached("v1/transactions") {
            transactions = page.transactions
            nextCursor = page.nextCursor
        }
    }

    var canLoadMore: Bool { nextCursor != nil }

    func load(search: String? = nil, reset: Bool = true) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var query = [URLQueryItem]()
            if let search, !search.isEmpty { query.append(.init(name: "search", value: search)) }
            let page: TransactionPage = try await api.get("v1/transactions", query: query)
            transactions = page.transactions
            nextCursor = page.nextCursor
            errorMessage = nil
            lastLoaded = Date()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func loadMore(search: String? = nil) async {
        guard let cursor = nextCursor, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var query = [URLQueryItem(name: "cursor", value: cursor)]
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
            return updated
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
