import Vapor
import Foundation
import BudgetModels

/// Shared savings goals (vacation, emergency fund) with a contribution ledger.
/// Goals are household-wide — both partners see and fund the same pot, so
/// there is no per-goal visibility. A contribution is attributed to whichever
/// member logged it.
func registerGoalRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())
    let goals = authed.grouped("goals")

    // GET /v1/goals
    goals.get { req async throws -> [Goal] in
        let (household, _) = try await req.requireMembership()
        return try await req.goals.list(householdID: household.id)
    }

    // POST /v1/goals
    goals.post { req async throws -> Goal in
        let (household, _) = try await req.requireMembership()
        var body = try req.content.decode(CreateGoalRequest.self)
        body.name = body.name.trimmingCharacters(in: .whitespaces)
        guard !body.name.isEmpty else {
            throw Abort(.badRequest, reason: "Goal name can't be empty.")
        }
        guard body.targetAmount > 0 else {
            throw Abort(.badRequest, reason: "Target amount must be positive.")
        }
        return try await req.goals.create(householdID: household.id, body)
    }

    // GET /v1/goals/:id — the goal plus its contribution history.
    goals.get(":id") { req async throws -> GoalDetailResponse in
        let goal = try await loadGoal(req)
        let contributions = try await req.goals.contributions(goalID: goal.id)
        return GoalDetailResponse(goal: goal, contributions: contributions)
    }

    // PATCH /v1/goals/:id
    goals.patch(":id") { req async throws -> Goal in
        let goal = try await loadGoal(req)
        let body = try req.content.decode(UpdateGoalRequest.self)
        if let name = body.name, name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw Abort(.badRequest, reason: "Goal name can't be empty.")
        }
        if let target = body.targetAmount, target <= 0 {
            throw Abort(.badRequest, reason: "Target amount must be positive.")
        }
        try await req.goals.update(id: goal.id, body)
        guard let updated = try await req.goals.get(id: goal.id) else {
            throw Abort(.internalServerError, reason: "Goal vanished during update")
        }
        return updated
    }

    // DELETE /v1/goals/:id — hard delete (contributions go with it).
    goals.delete(":id") { req async throws -> HTTPStatus in
        let goal = try await loadGoal(req)
        try await req.goals.delete(id: goal.id)
        return .ok
    }

    // POST /v1/goals/:id/contributions — add (positive) or withdraw (negative).
    goals.post(":id", "contributions") { req async throws -> GoalDetailResponse in
        let (_, member) = try await req.requireMembership()
        let goal = try await loadGoal(req)
        let body = try req.content.decode(AddContributionRequest.self)
        guard body.amount != 0 else {
            throw Abort(.badRequest, reason: "Contribution amount can't be zero.")
        }
        let (updated, _) = try await req.goals.addContribution(
            goalID: goal.id, amount: body.amount, date: body.date ?? Date(),
            memberID: member.id, note: body.note?.nilIfEmpty)
        let contributions = try await req.goals.contributions(goalID: goal.id)
        return GoalDetailResponse(goal: updated, contributions: contributions)
    }
}

/// Loads the goal in `:id`, 404ing when it doesn't exist or belongs to another
/// household (indistinguishable from absent, so nothing leaks).
private func loadGoal(_ req: Request) async throws -> Goal {
    let (household, _) = try await req.requireMembership()
    guard let id = req.parameters.get("id").flatMap({ UUID(uuidString: $0) }),
          let goal = try await req.goals.get(id: id),
          goal.householdID == household.id else {
        throw Abort(.notFound, reason: "Goal not found")
    }
    return goal
}
