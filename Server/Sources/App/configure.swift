import Vapor
import Foundation

/// App bootstrap: JSON coding, database, and routes. Called once from
/// `entrypoint.swift`. Mirrors FlightBag's configure/routes split.
public func configure(_ app: Application) async throws {
    // ISO8601 JSON on the wire, matched by the iOS client's decoder.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    // Uniform JSON error bodies ({ "error": true, "reason": "..." }).
    app.middleware = .init()
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))

    // Database: single SQLite file, path overridable for prod/volumes.
    let dbPath = Environment.get("BUDGET_DB_PATH")
        ?? app.directory.workingDirectory + "budget.sqlite"
    app.appDatabase = try AppDatabase(path: dbPath)
    app.logger.info("Database ready at \(dbPath)")

    try routes(app)
}
