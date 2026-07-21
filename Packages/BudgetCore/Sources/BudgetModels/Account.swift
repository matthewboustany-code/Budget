import Foundation

/// A financial account, sourced from Plaid and owned by one member. Its
/// `visibility` controls whether the partner can see it (Honeydue model).
public struct Account: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var householdID: UUID
    /// The member who linked this account; the only one who can see it while
    /// `visibility == .private`.
    public var ownerMemberID: UUID
    public var name: String
    public var officialName: String?
    public var type: AccountType
    /// Signed so liabilities can be negative if desired; net-worth math uses
    /// `type.isLiability` rather than the sign.
    public var currentBalance: Money
    public var availableBalance: Money?
    public var currencyCode: String
    public var institutionName: String?
    /// Last 2–4 digits, for disambiguating accounts at the same institution.
    public var mask: String?
    public var visibility: Visibility
    /// Hidden accounts stay linked and synced but are excluded from totals and
    /// most lists (e.g. a closed card kept for history).
    public var isHidden: Bool
    public var plaidAccountID: String?
    public var lastSyncedAt: Date?
    public var createdAt: Date

    public init(id: UUID, householdID: UUID, ownerMemberID: UUID, name: String,
                officialName: String? = nil, type: AccountType,
                currentBalance: Money, availableBalance: Money? = nil,
                currencyCode: String = "USD", institutionName: String? = nil,
                mask: String? = nil, visibility: Visibility = .shared,
                isHidden: Bool = false, plaidAccountID: String? = nil,
                lastSyncedAt: Date? = nil, createdAt: Date) {
        self.id = id
        self.householdID = householdID
        self.ownerMemberID = ownerMemberID
        self.name = name
        self.officialName = officialName
        self.type = type
        self.currentBalance = currentBalance
        self.availableBalance = availableBalance
        self.currencyCode = currencyCode
        self.institutionName = institutionName
        self.mask = mask
        self.visibility = visibility
        self.isHidden = isHidden
        self.plaidAccountID = plaidAccountID
        self.lastSyncedAt = lastSyncedAt
        self.createdAt = createdAt
    }

    /// Signed contribution to net worth: liabilities subtract, assets add.
    public var netWorthContribution: Money {
        type.isLiability ? -abs(currentBalance) : currentBalance
    }
}
