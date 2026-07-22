import Foundation
import Observation
import BudgetModels

/// Shared savings goals. The list is household-wide; contribution history is
/// fetched per goal for the detail screen. Mutations return the server's
/// updated state so callers can refresh their local copy immediately.
@MainActor
@Observable
final class GoalsStore {
    private let api: APIClient

    var goals: [Goal] = []
    var isLoading = false
    var errorMessage: String?

    init(api: APIClient) { self.api = api }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            goals = try await api.get("v1/goals")
            errorMessage = nil
        } catch {
            errorMessage = friendly(error)
        }
    }

    @discardableResult
    func create(_ request: CreateGoalRequest) async -> Bool {
        do {
            let goal: Goal = try await api.post("v1/goals", body: request)
            goals.append(goal)
            errorMessage = nil
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    func detail(_ goalID: UUID) async -> GoalDetailResponse? {
        do {
            let detail: GoalDetailResponse = try await api.get("v1/goals/\(goalID.uuidString)")
            replace(detail.goal)
            errorMessage = nil
            return detail
        } catch {
            errorMessage = friendly(error)
            return nil
        }
    }

    func update(_ goalID: UUID, _ request: UpdateGoalRequest) async -> Goal? {
        do {
            let updated: Goal = try await api.patch("v1/goals/\(goalID.uuidString)", body: request)
            replace(updated)
            errorMessage = nil
            return updated
        } catch {
            errorMessage = friendly(error)
            return nil
        }
    }

    @discardableResult
    func delete(_ goalID: UUID) async -> Bool {
        do {
            try await api.delete("v1/goals/\(goalID.uuidString)")
            goals.removeAll { $0.id == goalID }
            errorMessage = nil
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    /// Positive adds, negative withdraws. Returns the fresh detail (updated
    /// running total + full history) on success.
    func contribute(_ goalID: UUID, amount: Money, note: String?) async -> GoalDetailResponse? {
        do {
            let detail: GoalDetailResponse = try await api.post(
                "v1/goals/\(goalID.uuidString)/contributions",
                body: AddContributionRequest(amount: amount, note: note))
            replace(detail.goal)
            errorMessage = nil
            return detail
        } catch {
            errorMessage = friendly(error)
            return nil
        }
    }

    private func replace(_ goal: Goal) {
        if let index = goals.firstIndex(where: { $0.id == goal.id }) {
            goals[index] = goal
        } else {
            goals.append(goal)
        }
    }

    private func friendly(_ error: Error) -> String {
        (error as? APIClientError)?.errorDescription ?? error.localizedDescription
    }
}
