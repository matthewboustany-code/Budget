import Foundation

/// An authenticated person. Identity comes from Sign in with Apple; we store
/// the opaque `appleUserID` (the token `sub`) and never a password.
public struct User: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Stable, opaque Apple subject identifier.
    public var appleUserID: String
    /// Apple only provides this on first authorization; may be nil later.
    public var email: String?
    public var displayName: String
    public var createdAt: Date

    public init(id: UUID, appleUserID: String, email: String? = nil,
                displayName: String, createdAt: Date) {
        self.id = id
        self.appleUserID = appleUserID
        self.email = email
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

/// A shared budget space for a couple (or small group). All financial data
/// hangs off a household; a user belongs to at most one at a time in v1.
public struct Household: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// A user's membership in a household. `displayName` is per-household so the
/// same person can appear as "Alex" in one and "A" in another.
public struct HouseholdMember: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var householdID: UUID
    public var userID: UUID
    public var displayName: String
    public var role: MemberRole
    /// Avatar tint, hex like "#3B82F6". Optional; UI falls back to initials.
    public var colorHex: String?
    public var joinedAt: Date

    public init(id: UUID, householdID: UUID, userID: UUID, displayName: String,
                role: MemberRole, colorHex: String? = nil, joinedAt: Date) {
        self.id = id
        self.householdID = householdID
        self.userID = userID
        self.displayName = displayName
        self.role = role
        self.colorHex = colorHex
        self.joinedAt = joinedAt
    }
}

/// A single-use (per redemption) invite a partner enters to join a household.
public struct InviteCode: Codable, Sendable, Hashable {
    /// Short human-typeable code, e.g. "BUDGET-4F9K".
    public var code: String
    public var householdID: UUID
    public var expiresAt: Date

    public init(code: String, householdID: UUID, expiresAt: Date) {
        self.code = code
        self.householdID = householdID
        self.expiresAt = expiresAt
    }
}
