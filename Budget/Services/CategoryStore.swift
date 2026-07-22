import Foundation
import Observation
import BudgetModels

/// Loads and caches the household's category tree for display and the
/// recategorize picker.
@MainActor
@Observable
final class CategoryStore {
    private let api: APIClient

    var groups: [CategoryGroup] = []
    var categories: [BudgetCategory] = []
    private var byID: [UUID: BudgetCategory] = [:]

    init(api: APIClient) { self.api = api }

    func load() async {
        do {
            let response: CategoriesResponse = try await api.get("v1/categories")
            groups = response.groups.sorted { $0.sortOrder < $1.sortOrder }
            categories = response.categories.sorted { $0.sortOrder < $1.sortOrder }
            byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            // Non-fatal; the picker just shows fewer options.
        }
    }

    func name(for id: UUID?) -> String {
        guard let id, let category = byID[id] else { return "Uncategorized" }
        return category.name
    }

    func icon(for id: UUID?) -> String {
        (id.flatMap { byID[$0] })?.icon ?? "questionmark.circle"
    }

    /// Categories grouped by their group, in display order.
    func categoriesByGroup() -> [(group: CategoryGroup, categories: [BudgetCategory])] {
        groups.map { group in
            (group, categories.filter { $0.groupID == group.id })
        }.filter { !$0.categories.isEmpty }
    }
}
