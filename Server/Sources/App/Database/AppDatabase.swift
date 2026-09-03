import Foundation
import GRDB
import Vapor

/// The live application database: a GRDB `DatabasePool` (WAL mode, one writer +
/// concurrent readers) over a single SQLite file. Unlike FlightBag's read-only
/// shipped-artifact DB, this is a mutable multi-user store, so it uses GRDB's
/// `DatabaseMigrator` for versioned schema evolution (see Migrations.swift).
public final class AppDatabase: Sendable {
    public let dbPool: DatabasePool

    /// Why the file is encrypted, and what that does and doesn't buy:
    ///
    /// The database holds every transaction, balance and merchant either
    /// partner has. Encrypting the file protects it where it most plausibly
    /// leaks *away* from the running host — a VM snapshot, a copied Docker
    /// volume, a backup, a discarded disk. It does NOT protect against someone
    /// who already has the running server, because the key must be readable by
    /// the process to open the database at all. So keep the key out of whatever
    /// backs up the data volume; that separation is what makes this worth doing.
    public enum EncryptionError: Error, CustomStringConvertible {
        case sqlCipherUnavailable
        case wrongKey

        public var description: String {
            switch self {
            case .sqlCipherUnavailable:
                return """
                    BUDGET_DB_ENCRYPTION_KEY is set, but the linked SQLite is not                     SQLCipher, so the database would be written in the clear.                     Refusing to start rather than silently storing financial data                     unencrypted. The container image links SQLCipher; a plain                     macOS build does not.
                    """
            case .wrongKey:
                return """
                    The database could not be opened with BUDGET_DB_ENCRYPTION_KEY.                     Either the key is wrong, or the file is still plaintext and                     needs migrating (see Server/DEPLOY.md).
                    """
            }
        }
    }

    /// Opens (creating if needed) the database at `path` and runs migrations.
    ///
    /// Passing `encryptionKey` turns on SQLCipher. It is deliberately optional
    /// and *verified* rather than assumed: if the key is supplied but the linked
    /// library has no cipher, this throws instead of quietly writing plaintext.
    /// A security feature that fails open is worse than none, because it is
    /// believed.
    public init(path: String, encryptionKey: String? = nil) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // Reasonable busy timeout so brief writer contention retries instead of
        // failing immediately under concurrent sync + user writes.
        config.busyMode = .timeout(5)

        if let key = encryptionKey, !key.isEmpty {
            config.prepareDatabase { db in
                // Must be the very first statement on the connection.
                //
                // PRAGMA cannot take a bound parameter — SQLite parses the
                // pragma value at prepare time — so the key is inlined as a SQL
                // string literal, with embedded quotes doubled per SQL escaping
                // rules. `key` comes from our own environment, never from a
                // request, but escape it properly regardless.
                let quoted = "'" + key.replacingOccurrences(of: "'", with: "''") + "'"
                try db.execute(sql: "PRAGMA key = \(quoted)")

                // Confirm we are actually talking to SQLCipher. Plain SQLite
                // silently ignores an unknown pragma and returns no rows, which
                // is exactly the failure this check exists to catch.
                let cipher = try String.fetchOne(db, sql: "PRAGMA cipher_version")
                guard let cipher, !cipher.isEmpty else {
                    throw EncryptionError.sqlCipherUnavailable
                }

                // Force a real read: with a wrong key the header won't decrypt
                // and this is where it surfaces, rather than at some later query.
                do {
                    _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
                } catch {
                    throw EncryptionError.wrongKey
                }
            }
        }

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

    /// Non-fatal check used by `configure` so tests can inject a database before
    /// bootstrap (and so configure doesn't overwrite it).
    var appDatabaseIfConfigured: AppDatabase? { storage[AppDatabaseKey.self] }
}

extension Request {
    /// The application database, reachable from any route handler.
    public var appDatabase: AppDatabase { application.appDatabase }
}
