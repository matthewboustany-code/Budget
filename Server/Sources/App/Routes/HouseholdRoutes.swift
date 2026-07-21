import Vapor
import BudgetModels

/// Authenticated household routes: who am I, create/join a household, and
/// generate an invite code for a partner.
func registerHouseholdRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())

    // GET /v1/me — identity + current household (nil household → onboarding).
    authed.get("me") { req async throws -> MeResponse in
        try await me(req)
    }

    let household = authed.grouped("household")

    // POST /v1/household — create a household, becoming its owner.
    household.post { req async throws -> MeResponse in
        let user = try req.requireUser()
        let body = try req.content.decode(CreateHouseholdRequest.self)
        _ = try await req.households.create(
            name: body.name.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Our Budget",
            ownerUserID: user.id,
            ownerDisplayName: body.memberDisplayName.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? user.displayName)
        return try await me(req)
    }

    // GET /v1/household — the current household + all members.
    household.get { req async throws -> MeResponse in
        try await me(req)
    }

    // POST /v1/household/join — redeem an invite code.
    household.post("join") { req async throws -> MeResponse in
        let user = try req.requireUser()
        let body = try req.content.decode(JoinHouseholdRequest.self)
        _ = try await req.households.join(
            code: body.code,
            userID: user.id,
            displayName: body.memberDisplayName.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? user.displayName)
        return try await me(req)
    }

    // POST /v1/household/invite — a single-use code for the partner.
    household.post("invite") { req async throws -> InviteResponse in
        let user = try req.requireUser()
        guard let member = try await req.households.membership(userID: user.id) else {
            throw Abort(.forbidden, reason: "Create or join a household first.")
        }
        let invite = try await req.households.createInvite(householdID: member.householdID)
        return InviteResponse(code: invite.code, expiresAt: invite.expiresAt)
    }
}

/// Shared builder for the "me" payload (user + household + members).
private func me(_ req: Request) async throws -> MeResponse {
    let user = try req.requireUser()
    let member = try await req.households.membership(userID: user.id)
    var household: Household?
    var members: [HouseholdMember] = []
    if let member {
        household = try await req.households.household(id: member.householdID)
        members = try await req.households.members(householdID: member.householdID)
    }
    return MeResponse(user: user, household: household, member: member, members: members)
}
