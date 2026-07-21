import Foundation
import GRDB
import Vapor

/// The live application database: a GRDB `DatabasePool` (WAL mode, one writer +
/// concurrent readers) over a single SQLite file. Unlike FlightBag's read-only
/// shipped-artifact DB, this is a mutable multi-user store, so it uses GRDB's
/// `DatabaseMigrator` for versioned schema evolution (see Migrations.swift).
public final class AppDatabase: Sendable {
    public let dbPool: DatabasePool

    /// Opens (creating if needed) the database at `path` and runs migrations.
    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // Reasonable busy timeout so brief writer contention retries instead of
        // failing immediately under concurrent sync + user writes.
        config.busyMode = .timeout(5)
        self.dbPool = try DatabasePool(path: path, configuration: config)
        try Self.migrator.migrate(dbPool)
    }

    /// In-memory-ish database for tests: a throwaway file in the temp dir.
    public static func temporary() throws -> AppDatabase {
        let path = NSTemporaryDirectory() + "budget-test-\(UUID().uuidString).sqlite"
        return try AppDatabase(path: path)
    }
}

// MARK: - Application / Request wiring

extension Application {
    private struct AppDatabaseKey: StorageKey { typealias Value = AppDatabase }

    public var appDatabase: AppDatabase {
        get {
            guard let db = storage[AppDatabaseKey.self] else {
                fatalError("AppDatabase not configured. Call configure(app) first.")
            }
            return db
        }
        set { storage[AppDatabaseKey.self] = newValue }
    }
}

extension Request {
    /// The application database, reachable from any route handler.
    public var appDatabase: AppDatabase { application.appDatabase }
}
