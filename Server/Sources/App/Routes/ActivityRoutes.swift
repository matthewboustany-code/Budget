import Vapor
import BudgetModels

/// The partner activity feed (v1.1 §5.1): what the *other* household member
/// has said or reacted to, newest first. Your own comments never appear —
/// the feed exists to tell you something happened while you weren't looking.
func registerActivityRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())

    // GET /v1/activity?since=<iso8601>&limit=
    // `since` is the client's last-seen timestamp; omit it for the full page.
    authed.get("activity") { req async throws -> ActivityFeedResponse in
        let (household, member) = try await req.requireMembership()
        let since = req.query[String.self, at: "since"].flatMap(ISO8601DateFormatter().date(from:))
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 50, 1), 200)
        let events = try await req.activity.feed(householdID: household.id, memberID: member.id,
                                                 since: since, limit: limit)
        return ActivityFeedResponse(events: events)
    }
}
