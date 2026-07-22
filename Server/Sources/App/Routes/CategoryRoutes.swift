import Vapor
import BudgetModels

/// The household's category tree (used by the recategorize picker). Full CRUD
/// arrives in P4 (budgets); P3 exposes the seeded tree read-only.
func registerCategoryRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())

    authed.get("categories") { req async throws -> CategoriesResponse in
        let (household, _) = try await req.requireMembership()
        return try await req.categories.list(householdID: household.id)
    }
}
