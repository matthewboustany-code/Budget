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

/// Plaid's error envelope (returned with a non-2xx status).
struct PlaidErrorResponse: Decodable {
    let errorType: String?
    let errorCode: String?
    let errorMessage: String?
    let displayMessage: String?
}
