import Foundation
import GRDB
import Vapor
import BudgetModels

/// Daily net-worth snapshots, one row per household per day.
struct NetWorthStore {
    let db: DatabasePool

    func series(householdID: UUID) async throws -> [NetWorthPoint] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM net_worth_snapshots WHERE household_id = ? ORDER BY date",
                             arguments: [householdID.uuidString])
                .map { row in
                    NetWorthPoint(date: DBFormat.date(row["date"]) ?? Date(),
                                  assets: DBFormat.money(row["assets"]),
                                  liabilities: DBFormat.money(row["liabilities"]))
                }
        }
    }

    /// Upsert the snapshot for the point's day (UNIQUE(household_id, date)).
    func snapshot(householdID: UUID, point: NetWorthPoint) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO net_worth_snapshots (id, household_id, date, assets, liabilities)
                VALUES (?,?,?,?,?)
                ON CONFLICT(household_id, date) DO UPDATE SET
                    assets = excluded.assets, liabilities = excluded.liabilities
                """, arguments: [UUID().uuidString, householdID.uuidString,
                                 DBFormat.string(point.date), DBFormat.string(point.assets),
                                 DBFormat.string(point.liabilities)])
        }
    }
}

extension Request {
    var networth: NetWorthStore { NetWorthStore(db: appDatabase.dbPool) }
}
