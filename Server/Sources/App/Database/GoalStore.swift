import Foundation
import GRDB
import Vapor
import BudgetModels

/// Shared savings goals and their contribution history. `current_amount` is
/// denormalized (the sum of contributions) but always recomputed inside the
/// same write transaction that adds a contribution, so it can't drift.
struct GoalStore {
    let db: DatabasePool

    func list(householdID: UUID) async throws -> [Goal] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM goals WHERE household_id = ? ORDER BY created_at",
                             arguments: [householdID.uuidString]).map(Goal.init(row:))
        }
    }

    func get(id: UUID) async throws -> Goal? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM goals WHERE id = ?", arguments: [id.uuidString])
                .map(Goal.init(row:))
        }
    }

    func create(householdID: UUID, _ body: CreateGoalRequest) async throws -> Goal {
        let goal = Goal(id: UUID(), householdID: householdID, name: body.name,
                        targetAmount: body.targetAmount, targetDate: body.targetDate,
                        icon: body.icon, colorHex: body.colorHex, createdAt: Date())
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO goals (id, household_id, name, target_amount, current_amount,
                    target_date, icon, color_hex, created_at)
                VALUES (?,?,?,?,'0',?,?,?,?)
                """, arguments: [goal.id.uuidString, householdID.uuidString, goal.name,
                                 DBFormat.string(goal.targetAmount),
                                 goal.targetDate.map(DBFormat.string),
                                 goal.icon, goal.colorHex, DBFormat.string(goal.createdAt)])
        }
        return goal
    }

    /// PATCH semantics: only non-nil fields are applied.
    func update(id: UUID, _ body: UpdateGoalRequest) async throws {
        try await db.write { db in
            if let name = body.name {
                try db.execute(sql: "UPDATE goals SET name = ? WHERE id = ?",
                               arguments: [name, id.uuidString])
            }
            if let target = body.targetAmount {
                try db.execute(sql: "UPDATE goals SET target_amount = ? WHERE id = ?",
                               arguments: [DBFormat.string(target), id.uuidString])
            }
            if body.clearTargetDate == true {
                try db.execute(sql: "UPDATE goals SET target_date = NULL WHERE id = ?",
                               arguments: [id.uuidString])
            } else if let date = body.targetDate {
                try db.execute(sql: "UPDATE goals SET target_date = ? WHERE id = ?",
                               arguments: [DBFormat.string(date), id.uuidString])
            }
            if let icon = body.icon {
                try db.execute(sql: "UPDATE goals SET icon = ? WHERE id = ?",
                               arguments: [icon, id.uuidString])
            }
            if let colorHex = body.colorHex {
                try db.execute(sql: "UPDATE goals SET color_hex = ? WHERE id = ?",
                               arguments: [colorHex, id.uuidString])
            }
        }
    }

    /// Hard delete; contributions cascade via the schema.
    func delete(id: UUID) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM goals WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func contributions(goalID: UUID) async throws -> [GoalContribution] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM goal_contributions WHERE goal_id = ? ORDER BY date DESC",
                             arguments: [goalID.uuidString]).map(GoalContribution.init(row:))
        }
    }

    /// Insert the contribution and recompute the goal's running total in one
    /// transaction. Returns the updated goal alongside the new contribution.
    func addContribution(goalID: UUID, amount: Money, date: Date,
                         memberID: UUID, note: String?) async throws -> (Goal, GoalContribution) {
        let contribution = GoalContribution(id: UUID(), goalID: goalID, amount: amount,
                                            date: date, memberID: memberID, note: note)
        return try await db.write { db in
            try db.execute(sql: """
                INSERT INTO goal_contributions (id, goal_id, amount, date, member_id, note)
                VALUES (?,?,?,?,?,?)
                """, arguments: [contribution.id.uuidString, goalID.uuidString,
                                 DBFormat.string(amount), DBFormat.string(date),
                                 memberID.uuidString, note])
            let goal = try Self.recomputeTotal(goalID: goalID, db)
            return (goal, contribution)
        }
    }

    /// One contribution in the ledger, scoped to its goal so a caller can't
    /// reach another household's row by id alone.
    func contribution(id: UUID, goalID: UUID) async throws -> GoalContribution? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM goal_contributions WHERE id = ? AND goal_id = ?",
                             arguments: [id.uuidString, goalID.uuidString])
                .map(GoalContribution.init(row:))
        }
    }

    /// PATCH semantics: only non-nil fields are applied. The goal's running
    /// total is recomputed in the same transaction as the edit, so the ledger
    /// and `current_amount` can never disagree.
    func updateContribution(id: UUID, goalID: UUID,
                            _ body: UpdateContributionRequest) async throws -> Goal {
        try await db.write { db in
            if let amount = body.amount {
                try db.execute(sql: "UPDATE goal_contributions SET amount = ? WHERE id = ? AND goal_id = ?",
                               arguments: [DBFormat.string(amount), id.uuidString, goalID.uuidString])
            }
            if let date = body.date {
                try db.execute(sql: "UPDATE goal_contributions SET date = ? WHERE id = ? AND goal_id = ?",
                               arguments: [DBFormat.string(date), id.uuidString, goalID.uuidString])
            }
            if body.clearNote == true {
                try db.execute(sql: "UPDATE goal_contributions SET note = NULL WHERE id = ? AND goal_id = ?",
                               arguments: [id.uuidString, goalID.uuidString])
            } else if let note = body.note {
                try db.execute(sql: "UPDATE goal_contributions SET note = ? WHERE id = ? AND goal_id = ?",
                               arguments: [note, id.uuidString, goalID.uuidString])
            }
            return try Self.recomputeTotal(goalID: goalID, db)
        }
    }

    func deleteContribution(id: UUID, goalID: UUID) async throws -> Goal {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM goal_contributions WHERE id = ? AND goal_id = ?",
                           arguments: [id.uuidString, goalID.uuidString])
            return try Self.recomputeTotal(goalID: goalID, db)
        }
    }

    /// Sum the ledger and write it back to the goal. Always called inside the
    /// caller's write transaction — never on its own.
    private static func recomputeTotal(goalID: UUID, _ db: Database) throws -> Goal {
        let amounts = try String.fetchAll(
            db, sql: "SELECT amount FROM goal_contributions WHERE goal_id = ?",
            arguments: [goalID.uuidString])
        let total = amounts.reduce(Money(0)) { $0 + DBFormat.money($1) }
        try db.execute(sql: "UPDATE goals SET current_amount = ? WHERE id = ?",
                       arguments: [DBFormat.string(total), goalID.uuidString])
        guard let goal = try Row.fetchOne(db, sql: "SELECT * FROM goals WHERE id = ?",
                                          arguments: [goalID.uuidString]).map(Goal.init(row:)) else {
            throw Abort(.internalServerError, reason: "Goal vanished during contribution")
        }
        return goal
    }
}

extension Request {
    var goals: GoalStore { GoalStore(db: appDatabase.dbPool) }
}
