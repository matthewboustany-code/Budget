import Foundation
import Observation
import BudgetModels
import BudgetKit

/// Cash flow and spending reports, plus the month being inspected on the
/// spending report. Cash flow always covers the trailing six months ending
/// now (what the dashboard and the trend chart both show).
@MainActor
@Observable
final class ReportsStore {
    private let api: APIClient

    var cashFlow: [CashFlowSummary] = []
    var spending: SpendingReportResponse?
    var spendingMonth = Month(date: Date())
    var isLoading = false
    var errorMessage: String?

    init(api: APIClient) { self.api = api }

    /// This month's income/expenses — the dashboard card.
    var currentMonth: CashFlowSummary? { cashFlow.last }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let flow: CashFlowReportResponse = api.get(
                "v1/reports/cashflow", query: [.init(name: "months", value: "6")])
            async let spend: SpendingReportResponse = api.get(
                "v1/reports/spending",
                query: [.init(name: "month", value: spendingMonth.description)])
            cashFlow = try await flow.months
            spending = try await spend
            errorMessage = nil
        } catch {
            errorMessage = friendly(error)
        }
    }

    func showPreviousSpendingMonth() async {
        spendingMonth = spendingMonth.previous
        await loadSpending()
    }

    func showNextSpendingMonth() async {
        spendingMonth = spendingMonth.next
        await loadSpending()
    }

    private func loadSpending() async {
        do {
            spending = try await api.get(
                "v1/reports/spending",
                query: [.init(name: "month", value: spendingMonth.description)])
            errorMessage = nil
        } catch {
            errorMessage = friendly(error)
        }
    }

    private func friendly(_ error: Error) -> String {
        (error as? APIClientError)?.errorDescription ?? error.localizedDescription
    }
}
