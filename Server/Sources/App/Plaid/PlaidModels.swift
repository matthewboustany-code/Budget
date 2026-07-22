import Foundation

// Plaid wire types. Swift properties are camelCase; the client encodes/decodes
// with snake_case conversion so they match Plaid's JSON (client_id, access_token…).

// MARK: - Requests

struct PlaidLinkTokenCreateRequest: Encodable {
    let clientId: String
    let secret: String
    let clientName: String
    let language: String
    let countryCodes: [String]
    let user: User
    let products: [String]
    let webhook: String?
    struct User: Encodable { let clientUserId: String }
}

struct PlaidExchangeRequest: Encodable {
    let clientId: String
    let secret: String
    let publicToken: String
}

struct PlaidAccessTokenRequest: Encodable {
    let clientId: String
    let secret: String
    let accessToken: String
}

struct PlaidTransactionsSyncRequest: Encodable {
    let clientId: String
    let secret: String
    let accessToken: String
    let cursor: String?
    let count: Int
}

struct PlaidSandboxPublicTokenRequest: Encodable {
    let clientId: String
    let secret: String
    let institutionId: String
    let initialProducts: [String]
}

// MARK: - Responses

struct PlaidLinkTokenCreateResponse: Decodable {
    let linkToken: String
    let expiration: String?
}

struct PlaidExchangeResponse: Decodable {
    let accessToken: String
    let itemId: String
}

struct PlaidSandboxPublicTokenResponse: Decodable {
    let publicToken: String
}

struct PlaidAccountsResponse: Decodable {
    let accounts: [PlaidAccount]
    let item: PlaidItemInfo?
}

struct PlaidItemInfo: Decodable {
    let institutionId: String?
}

struct PlaidAccount: Decodable {
    let accountId: String
    let name: String
    let officialName: String?
    let mask: String?
    let type: String
    let subtype: String?
    let balances: PlaidBalances
}

struct PlaidBalances: Decodable {
    let current: Double?
    let available: Double?
    let isoCurrencyCode: String?
}

struct PlaidTransactionsSyncResponse: Decodable {
    let added: [PlaidTransaction]
    let modified: [PlaidTransaction]
    let removed: [PlaidRemovedTransaction]
    let nextCursor: String
    let hasMore: Bool
}

struct PlaidRemovedTransaction: Decodable {
    let transactionId: String
}

struct PlaidTransaction: Decodable {
    let transactionId: String
    let accountId: String
    let amount: Double
    let isoCurrencyCode: String?
    let date: String                       // "YYYY-MM-DD"
    let name: String
    let merchantName: String?
    let pending: Bool
    let personalFinanceCategory: PlaidPFC?
}

struct PlaidPFC: Decodable {
    let primary: String?
    let detailed: String?
}

/// Plaid's error envelope (returned with a non-2xx status).
struct PlaidErrorResponse: Decodable {
    let errorType: String?
    let errorCode: String?
    let errorMessage: String?
    let displayMessage: String?
}
