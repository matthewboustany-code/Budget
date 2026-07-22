import Vapor
import BudgetModels

/// The household's category tree: read for the pickers, plus create / edit /
/// archive for custom categories (P4). Groups stay fixed (the seeded set) —
/// categories are the unit couples customize.
func registerCategoryRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())
    let categories = authed.grouped("categories")

    categories.get { req async throws -> CategoriesResponse in
        let (household, _) = try await req.requireMembership()
        return try await req.categories.list(householdID: household.id)
    }

    // POST /v1/categories — add a custom category to an existing group.
    categories.post { req async throws -> BudgetCategory in
        let (household, _) = try await req.requireMembership()
        let body = try req.content.decode(CreateCategoryRequest.self)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Abort(.badRequest, reason: "Category name can't be empty.") }
        guard let group = try await req.categories.getGroup(id: body.groupID),
              group.householdID == household.id else {
            throw Abort(.notFound, reason: "Category group not found")
        }
        return try await req.categories.create(householdID: household.id, groupID: group.id,
                                               name: name, icon: body.icon, colorHex: body.colorHex)
    }

    // PATCH /v1/categories/:id — rename / restyle / reorder / (un)archive.
    categories.patch(":id") { req async throws -> BudgetCategory in
        let (category, _) = try await loadCategory(req)
        var body = try req.content.decode(UpdateCategoryRequest.self)
        if let name = body.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Abort(.badRequest, reason: "Category name can't be empty.") }
            body.name = trimmed
        }
        try await req.categories.update(id: category.id, body)
        return try await req.categories.get(id: category.id) ?? category
    }

    // DELETE /v1/categories/:id — archives (keeps transaction history intact).
    categories.delete(":id") { req async throws -> HTTPStatus in
        let (category, _) = try await loadCategory(req)
        try await req.categories.archive(id: category.id)
        return .ok
    }
}

/// Loads the `:id` category, enforcing household scope.
private func loadCategory(_ req: Request) async throws -> (BudgetCategory, HouseholdMember) {
    let (household, member) = try await req.requireMembership()
    guard let id = req.parameters.get("id").flatMap({ UUID(uuidString: $0) }) else {
        throw Abort(.badRequest, reason: "Invalid category id")
    }
    guard let category = try await req.categories.get(id: id), category.householdID == household.id else {
        throw Abort(.notFound, reason: "Category not found")
    }
    return (category, member)
}
