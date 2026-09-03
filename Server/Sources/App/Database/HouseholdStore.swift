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

    /// All households (for the nightly net-worth snapshot command).
    func allHouseholds() async throws -> [Household] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM households").map(Household.init(row:))
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
            try CategorySeeder.seed(householdID: household.id, db)   // default category tree
        }
        return (household, member)
    }

    /// Redeems an invite code, adding the user to that household. The code is
    /// single-use and deleted on success.
    func join(code: String, userID: UUID, displayName: String) async throws -> (Household, HouseholdMember) {
        if try await membership(userID: userID) != nil {
            throw Abort(.conflict, reason: "You are already in a household.")
        }
        let normalized = Self.normalizeCode(code)
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
            // Stored normalized so lookups match however the partner types it.
            try db.execute(sql: "INSERT INTO invite_codes (code, household_id, expires_at) VALUES (?, ?, ?)",
                           arguments: [Self.normalizeCode(code), householdID.uuidString,
                                       DBFormat.string(expiresAt)])
        }
        // The dashed form is what we show the user.
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

    /// "BUDGET-XXXXX-XXXXX" using an unambiguous alphabet (no O/0/I/1).
    ///
    /// Ten characters over a 32-symbol alphabet is 2^50. The previous six
    /// characters were only 2^30, which sounds large but is not: redeeming a
    /// code grants full access to a household's finances, and an attacker
    /// making 1000 guesses/sec would expect to land one in about six days.
    /// Grouped with a dash purely so it can be read aloud; `normalizeCode`
    /// strips the grouping, so either form can be typed.
    static func generateCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        let chars = (0..<10).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
        return "BUDGET-\(String(chars[0..<5]))-\(String(chars[5..<10]))"
    }

    /// Canonical form for storage and lookup: uppercase, no spaces, and with
    /// the readability dashes removed so "budget-abcde-fghjk", "BUDGETABCDEFGHJK"
    /// and the printed form all resolve to the same code.
    static func normalizeCode(_ raw: String) -> String {
        raw.uppercased()
            .components(separatedBy: CharacterSet(charactersIn: "- \t"))
            .joined()
    }
}

extension Request {
    var households: HouseholdStore { HouseholdStore(db: appDatabase.dbPool) }
}
