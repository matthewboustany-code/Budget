import Foundation
import GRDB
import Vapor
import BudgetModels

/// Data access for households, memberships, and invite codes.
struct HouseholdStore {
    let db: DatabasePool

    // MARK: Membership lookup

    /// The membership row for a user, if they belong to a household (v1: ≤ 1).
    func membership(userID: UUID) async throws -> HouseholdMember? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM memberships WHERE user_id = ? LIMIT 1",
                             arguments: [userID.uuidString])
                .map(HouseholdMember.init(row:))
        }
    }

    func household(id: UUID) async throws -> Household? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM households WHERE id = ?", arguments: [id.uuidString])
                .map(Household.init(row:))
        }
    }

    func members(householdID: UUID) async throws -> [HouseholdMember] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM memberships WHERE household_id = ? ORDER BY joined_at",
                             arguments: [householdID.uuidString])
                .map(HouseholdMember.init(row:))
        }
    }

    // MARK: Create / join

    /// Creates a household and makes the user its owner. Fails if the user is
    /// already in a household.
    func create(name: String, ownerUserID: UUID, ownerDisplayName: String) async throws -> (Household, HouseholdMember) {
        if try await membership(userID: ownerUserID) != nil {
            throw Abort(.conflict, reason: "You are already in a household.")
        }
        let household = Household(id: UUID(), name: name, createdAt: Date())
        let member = HouseholdMember(id: UUID(), householdID: household.id, userID: ownerUserID,
                                     displayName: ownerDisplayName, role: .owner, joinedAt: Date())
        try await db.write { db in
            try db.execute(sql: "INSERT INTO households (id, name, created_at) VALUES (?, ?, ?)",
                           arguments: [household.id.uuidString, household.name, DBFormat.string(household.createdAt)])
            try Self.insertMember(member, db)
        }
        return (household, member)
    }

    /// Redeems an invite code, adding the user to that household. The code is
    /// single-use and deleted on success.
    func join(code: String, userID: UUID, displayName: String) async throws -> (Household, HouseholdMember) {
        if try await membership(userID: userID) != nil {
            throw Abort(.conflict, reason: "You are already in a household.")
        }
        let normalized = code.uppercased().trimmingCharacters(in: .whitespaces)
        return try await db.write { db in
            guard let inviteRow = try Row.fetchOne(
                db, sql: "SELECT * FROM invite_codes WHERE code = ?", arguments: [normalized])
            else { throw Abort(.notFound, reason: "That invite code isn't valid.") }

            let expiresAt = DBFormat.date(inviteRow["expires_at"]) ?? .distantPast
            guard expiresAt > Date() else {
                try db.execute(sql: "DELETE FROM invite_codes WHERE code = ?", arguments: [normalized])
                throw Abort(.gone, reason: "That invite code has expired.")
            }
            let householdID = DBFormat.uuid(inviteRow["household_id"]) ?? UUID()
            guard let householdRow = try Row.fetchOne(
                db, sql: "SELECT * FROM households WHERE id = ?", arguments: [householdID.uuidString])
            else { throw Abort(.notFound, reason: "That household no longer exists.") }

            let household = Household(row: householdRow)
            let member = HouseholdMember(id: UUID(), householdID: householdID, userID: userID,
                                         displayName: displayName, role: .member, joinedAt: Date())
            try Self.insertMember(member, db)
            try db.execute(sql: "DELETE FROM invite_codes WHERE code = ?", arguments: [normalized])
            return (household, member)
        }
    }

    // MARK: Invites

    /// Generates a single-use invite code for a household, valid for `ttl`.
    func createInvite(householdID: UUID, ttl: TimeInterval = 7 * 24 * 3600) async throws -> InviteCode {
        let code = Self.generateCode()
        let expiresAt = Date().addingTimeInterval(ttl)
        try await db.write { db in
            try db.execute(sql: "INSERT INTO invite_codes (code, household_id, expires_at) VALUES (?, ?, ?)",
                           arguments: [code, householdID.uuidString, DBFormat.string(expiresAt)])
        }
        return InviteCode(code: code, householdID: householdID, expiresAt: expiresAt)
    }

    // MARK: Helpers

    private static func insertMember(_ m: HouseholdMember, _ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO memberships (id, household_id, user_id, display_name, role, color_hex, joined_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [m.id.uuidString, m.householdID.uuidString, m.userID.uuidString,
                        m.displayName, m.role.rawValue, m.colorHex, DBFormat.string(m.joinedAt)])
    }

    /// "BUDGET-XXXXXX" using an unambiguous alphabet (no O/0/I/1).
    private static func generateCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let suffix = String((0..<6).map { _ in alphabet.randomElement()! })
        return "BUDGET-\(suffix)"
    }
}

extension Request {
    var households: HouseholdStore { HouseholdStore(db: appDatabase.dbPool) }
}
