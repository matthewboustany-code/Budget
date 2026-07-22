import Foundation
import Observation
import BudgetModels
import BudgetKit

/// Monthly budget state for the Budget tab: the selected month, its stored
/// budgets (amount + rollover flag for the editor), and the server-computed
/// budget-vs-actual rollup.
@MainActor
@Observable
final class BudgetStore {
    private let api: APIClient

    var month = Month(date: Date())
    var budgets: [Budget] = []
    var rollup: MonthBudget?
    var isLoading = false
    var errorMessage: String?

    private var budgetByCategory: [UUID: Budget] = [:]
    private var progressByCategory: [UUID: BudgetProgress] = [:]

    init(api: APIClient) { self.api = api }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: BudgetMonthResponse = try await api.get(
                "v1/budgets", query: [.init(name: "month", value: month.description)])
            budgets = response.budgets
            rollup = response.rollup
            budgetByCategory = Dictionary(budgets.map { ($0.categoryID, $0) },
                                          uniquingKeysWith: { first, _ in first })
            progressByCategory = Dictionary(response.rollup.entries.map { ($0.categoryID, $0) },
                                            uniquingKeysWith: { first, _ in first })
            errorMessage = nil
        } catch {
            errorMessage = friendly(error)
        }
    }

    func showPreviousMonth() async {
        month = month.previous
        await load()
    }

    func showNextMonth() async {
        month = month.next
        await load()
    }

    /// Upserts the category's budget for the displayed month, then reloads so
    /// the rollup (including any rollover chain) stays server-authoritative.
    @discardableResult
    func setBudget(categoryID: UUID, amount: Money, rolloverEnabled: Bool) async -> Bool {
        do {
            let _: Budget = try await api.put(
                "v1/budgets/\(categoryID.uuidString)",
                body: SetBudgetRequest(month: month, amount: amount, rolloverEnabled: rolloverEnabled))
            await load()
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    func budget(for categoryID: UUID) -> Budget? { budgetByCategory[categoryID] }
    func progress(for categoryID: UUID) -> BudgetProgress? { progressByCategory[categoryID] }

    private func friendly(_ error: Error) -> String {
        (error as? APIClientError)?.errorDescription ?? error.localizedDescription
    }
}
