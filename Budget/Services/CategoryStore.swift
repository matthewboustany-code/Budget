import Foundation
import Observation
import BudgetModels

/// Loads and caches the household's category tree for display and the
/// recategorize picker, plus the management calls behind Settings ›
/// Categories (create / rename / icon / archive / reorder) and the
/// household's category rules.
@MainActor
@Observable
final class CategoryStore {
    private let api: APIClient

    var groups: [CategoryGroup] = []
    /// Active categories — what every picker offers.
    var categories: [BudgetCategory] = []
    /// Archived ones, for the management screen's Restore list.
    var archived: [BudgetCategory] = []
    var rules: [CategoryRule] = []
    var errorMessage: String?
    /// Every category incl. archived, so old transactions still show a real
    /// name instead of "Uncategorized".
    private var byID: [UUID: BudgetCategory] = [:]
    private(set) var lastLoaded: Date?

    init(api: APIClient) { self.api = api }

    func load() async {
        do {
            let response: CategoriesResponse = try await api.get(
                "v1/categories", query: [.init(name: "includeArchived", value: "1")])
            groups = response.groups.sorted { $0.sortOrder < $1.sortOrder }
            let all = response.categories.sorted { $0.sortOrder < $1.sortOrder }
            categories = all.filter { !$0.isArchived }
            archived = all.filter(\.isArchived)
            byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            lastLoaded = Date()
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

    // MARK: - Management

    @discardableResult
    func create(groupID: UUID, name: String, icon: String?) async -> Bool {
        await run {
            let _: BudgetCategory = try await self.api.post(
                "v1/categories", body: CreateCategoryRequest(groupID: groupID, name: name, icon: icon))
        }
    }

    @discardableResult
    func update(_ id: UUID, _ request: UpdateCategoryRequest) async -> Bool {
        await run {
            let _: BudgetCategory = try await self.api.patch("v1/categories/\(id.uuidString)", body: request)
        }
    }

    /// Archive, never delete: transactions and budgets keep their history.
    func archive(_ id: UUID) async {
        await run { try await self.api.delete("v1/categories/\(id.uuidString)") }
    }

    func restore(_ id: UUID) async {
        await update(id, .init(isArchived: false))
    }

    /// Reorders one group's categories: renumbers 1…n locally (so the list
    /// doesn't snap back) and PATCHes only the rows whose position changed.
    func move(in groupID: UUID, from source: IndexSet, to destination: Int) async {
        // `.onMove` semantics, without SwiftUI's Array.move in a service:
        // `destination` indexes the list *before* the moved rows are removed.
        var list = categories.filter { $0.groupID == groupID }
        let moving = source.sorted().map { list[$0] }
        let shift = source.filter { $0 < destination }.count
        list = list.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        list.insert(contentsOf: moving, at: destination - shift)
        var changed: [(UUID, Int)] = []
        for (index, var category) in list.enumerated() where category.sortOrder != index + 1 {
            category.sortOrder = index + 1
            changed.append((category.id, index + 1))
            if let i = categories.firstIndex(where: { $0.id == category.id }) { categories[i] = category }
        }
        categories.sort { $0.sortOrder < $1.sortOrder }
        for (id, order) in changed {
            do {
                let _: BudgetCategory = try await api.patch("v1/categories/\(id.uuidString)",
                                                            body: UpdateCategoryRequest(sortOrder: order))
            } catch {
                errorMessage = friendly(error)
                break
            }
        }
        await load()
    }

    // MARK: - Rules

    func loadRules() async {
        do { rules = try await api.get("v1/category-rules") }
        catch { errorMessage = friendly(error) }
    }

    func deleteRule(_ rule: CategoryRule) async {
        do {
            try await api.delete("v1/category-rules/\(rule.id.uuidString)")
            rules.removeAll { $0.id == rule.id }
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Runs a mutation, then reloads the tree; false (with `errorMessage`) on failure.
    private func run(_ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            errorMessage = nil
            await load()
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
