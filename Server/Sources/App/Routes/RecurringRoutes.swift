import Vapor
import Foundation
import BudgetModels
import BudgetKit

/// Recurring series (detected subscriptions/bills) and the upcoming-bills
/// projection. Series come from `RecurringDetector` (run after every sync and
/// via the explicit refresh below); bills are never stored — `BillProjector`
/// recomputes occurrences from the caller's visible active series on each
/// read, so the app and server always agree.
func registerRecurringRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())
    let recurring = authed.grouped("recurring")

    // GET /v1/recurring — the caller's visible series, soonest first.
    recurring.get { req async throws -> [RecurringSeries] in
        let (household, member) = try await req.requireMembership()
        return try await req.recurring.listVisible(householdID: household.id, memberID: member.id)
    }

    // POST /v1/recurring/refresh — re-run detection now (the Bills screen's
    // pull-to-refresh; sync also refreshes automatically).
    recurring.post("refresh") { req async throws -> [RecurringSeries] in
        let (household, member) = try await req.requireMembership()
        try await req.recurringService.refresh(householdID: household.id)
        return try await req.recurring.listVisible(householdID: household.id, memberID: member.id)
    }

    // PATCH /v1/recurring/:id — rename, recategorize, or toggle active.
    recurring.patch(":id") { req async throws -> RecurringSeries in
        let (household, member) = try await req.requireMembership()
        let series = try await loadVisibleSeries(req, household: household, member: member)
        let body = try req.content.decode(UpdateRecurringRequest.self)

        if let name = body.name, name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw Abort(.badRequest, reason: "Name can't be empty.")
        }
        if let categoryID = body.categoryID {
            guard let category = try await req.categories.get(id: categoryID),
                  category.householdID == household.id else {
                throw Abort(.notFound, reason: "Category not found")
            }
        }
        try await req.recurring.update(id: series.id, body)
        guard let updated = try await req.recurring.get(id: series.id) else {
            throw Abort(.internalServerError, reason: "Series vanished during update")
        }
        return updated
    }

    // GET /v1/bills/upcoming?days=30 — occurrences projected over the window,
    // including a two-week look-back so a bill that was due but hasn't posted
    // yet shows as overdue instead of silently disappearing.
    authed.grouped("bills").get("upcoming") { req async throws -> UpcomingBillsResponse in
        let (household, member) = try await req.requireMembership()
        let days = min(max(req.query[Int.self, at: "days"] ?? 30, 1), 365)

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -14, to: today) ?? today
        let to = calendar.date(byAdding: .day, value: days, to: today) ?? today

        let series = try await req.recurring.listVisible(householdID: household.id,
                                                         memberID: member.id)
        let bills = BillProjector.upcomingBills(series: series, from: from, to: to,
                                                now: now, calendar: calendar)
        return UpcomingBillsResponse(from: from, to: to, bills: bills)
    }
}

/// Loads a series by id, 404ing when it doesn't exist, belongs to another
/// household, or is drawn from a private account the caller doesn't own
/// (indistinguishable from absent, so nothing leaks).
private func loadVisibleSeries(_ req: Request, household: Household,
                               member: HouseholdMember) async throws -> RecurringSeries {
    guard let id = req.parameters.get("id").flatMap({ UUID(uuidString: $0) }),
          let series = try await req.recurring.get(id: id),
          series.householdID == household.id else {
        throw Abort(.notFound, reason: "Recurring series not found")
    }
    if let accountID = series.accountID,
       let account = try await req.accounts.get(id: accountID),
       account.visibility == .private && account.ownerMemberID != member.id {
        throw Abort(.notFound, reason: "Recurring series not found")
    }
    return series
}
