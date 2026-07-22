import Vapor
import Foundation
import JWT

/// App bootstrap: JSON coding, config, JWT keys, database, and routes. Called
/// once from `entrypoint.swift`. Mirrors FlightBag's configure/routes split.
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

    // Configuration from the environment (.env).
    app.appConfig = AppConfig.load(app.environment)
    if app.appConfig.authDevMode {
        app.logger.warning("AUTH_DEV_MODE is ON — dev sign-in accepted. Do not use in production.")
    }

    // Sign our session bearer tokens with the HMAC secret.
    await app.jwt.keys.add(hmac: .init(from: app.appConfig.sessionJWTSecret), digestAlgorithm: .sha256)

    // Database: single SQLite file, path overridable for prod/volumes. Tests may
    // inject their own database before calling configure; don't overwrite it.
    if app.appDatabaseIfConfigured == nil {
        let dbPath = Environment.get("BUDGET_DB_PATH")
            ?? app.directory.workingDirectory + "budget.sqlite"
        app.appDatabase = try AppDatabase(path: dbPath)
        app.logger.info("Database ready at \(dbPath)")
    }

    // Scheduled jobs, run by cron (see scripts/). Never HTTP-triggered.
    app.asyncCommands.use(SyncAllItemsCommand(), as: "sync-all")
    app.asyncCommands.use(NetWorthSnapshotCommand(), as: "networth-snapshot")
    app.asyncCommands.use(BillReminderCommand(), as: "bill-reminder")

    try routes(app)
}
