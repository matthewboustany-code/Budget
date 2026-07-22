import Foundation
import Observation
import BudgetModels

/// State for the Bills screen: detected recurring series and the projected
/// upcoming occurrences. Bills are server-computed from the visible active
/// series, so every mutation reloads both lists to stay authoritative.
@MainActor
@Observable
final class BillsStore {
    private let api: APIClient

    var series: [RecurringSeries] = []
    var bills: [Bill] = []
    var isLoading = false
    var errorMessage: String?

    init(api: APIClient) { self.api = api }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let seriesResponse: [RecurringSeries] = api.get("v1/recurring")
            async let billsResponse: UpcomingBillsResponse = api.get("v1/bills/upcoming")
            series = try await seriesResponse
            bills = try await billsResponse.bills
            errorMessage = nil
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Re-runs detection server-side (pull-to-refresh), then reloads bills.
    func redetect() async {
        isLoading = true
        defer { isLoading = false }
        do {
            series = try await api.post("v1/recurring/refresh", body: Empty())
            let response: UpcomingBillsResponse = try await api.get("v1/bills/upcoming")
            bills = response.bills
            errorMessage = nil
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Toggle "this is a real recurring bill" on a series. Off means the
    /// detector was wrong (or the subscription is cancelled) — its projected
    /// bills disappear and detection won't turn it back on.
    @discardableResult
    func setActive(_ seriesID: UUID, _ isActive: Bool) async -> Bool {
        await update(seriesID, UpdateRecurringRequest(isActive: isActive))
    }

    @discardableResult
    func update(_ seriesID: UUID, _ request: UpdateRecurringRequest) async -> Bool {
        do {
            let updated: RecurringSeries = try await api.patch(
                "v1/recurring/\(seriesID.uuidString)", body: request)
            if let index = series.firstIndex(where: { $0.id == seriesID }) {
                series[index] = updated
            }
            let response: UpcomingBillsResponse = try await api.get("v1/bills/upcoming")
            bills = response.bills
            errorMessage = nil
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    private func friendly(_ error: Error) -> String {
        (error as? APIClientError)?.errorDescription ?? error.localizedDescription
    }
}
