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

    /// Net worth over time from only the accounts this member can see — the
    /// same rule as `AccountStore.visibleAccounts` — so the series and the
    /// caller's `current` agree. Hidden accounts are never snapshotted.
    func series(householdID: UUID, memberID: UUID) async throws -> [NetWorthPoint] {
        try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.date, s.current, a.type FROM account_balance_snapshots s
                JOIN accounts a ON a.id = s.account_id
                WHERE a.household_id = ? AND (a.visibility = 'shared' OR a.owner_member_id = ?)
                ORDER BY s.date
                """, arguments: [householdID.uuidString, memberID.uuidString])
            var byDate: [String: (assets: Money, liabilities: Money)] = [:]
            var order: [String] = []
            for row in rows {
                let date: String = row["date"]
                let balance = DBFormat.money(row["current"])
                let isLiability = AccountType(rawValue: row["type"])?.isLiability ?? false
                if byDate[date] == nil { order.append(date); byDate[date] = (0, 0) }
                if isLiability { byDate[date]!.liabilities += abs(balance) } else { byDate[date]!.assets += balance }
            }
            return order.map { date in
                NetWorthPoint(date: DBFormat.date(date) ?? Date(),
                              assets: byDate[date]!.assets, liabilities: byDate[date]!.liabilities)
            }
        }
    }

    /// Upsert one row per account for the day (UNIQUE(account_id, date)).
    func snapshotAccounts(_ accounts: [Account], date: Date) async throws {
        try await db.write { db in
            for account in accounts {
                try db.execute(sql: """
                    INSERT INTO account_balance_snapshots (id, account_id, date, current, available)
                    VALUES (?,?,?,?,?)
                    ON CONFLICT(account_id, date) DO UPDATE SET
                        current = excluded.current, available = excluded.available
                    """, arguments: [UUID().uuidString, account.id.uuidString, DBFormat.string(date),
                                     DBFormat.string(account.currentBalance),
                                     account.availableBalance.map(DBFormat.string)])
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
