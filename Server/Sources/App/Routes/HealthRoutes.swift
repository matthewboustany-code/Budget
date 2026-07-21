import Vapor
import GRDB

/// Liveness/readiness probe. Confirms the process is up and the database is
/// reachable, so the app's first launch and deploy scripts can verify the
/// server end-to-end before anything else exists.
func registerHealthRoutes(_ routes: RoutesBuilder) throws {
    routes.get("health") { req async throws -> HealthResponse in
        let ok = try await req.appDatabase.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT 1") == 1
        }
        return HealthResponse(status: ok ? "ok" : "degraded",
                              database: ok,
                              time: Date())
    }
}

struct HealthResponse: Content {
    var status: String
    var database: Bool
    var time: Date
}
