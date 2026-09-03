import Foundation
import Vapor
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstracts the HTTP POST so the real client hits Plaid while tests inject
/// canned fixtures (mirrors FlightBag's injectable `HTTPGetting`).
protocol PlaidTransport: Sendable {
    func post(url: URL, json: Data) async throws -> (data: Data, status: Int)
}

/// Real transport over URLSession (fine on the server: async, off the event loop).
struct URLSessionPlaidTransport: PlaidTransport {
    func post(url: URL, json: Data) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum PlaidError: Error, CustomStringConvertible {
    case badURL
    case api(status: Int, code: String?, message: String)

    var description: String {
        switch self {
        case .badURL: return "Invalid Plaid URL"
        case .api(let status, let code, let message):
            return "Plaid \(status)\(code.map { " \($0)" } ?? ""): \(message)"
        }
    }
}

/// Typed Plaid API client. `clientId`/`secret` are injected into every request
/// body (Plaid's auth model). Base URL is chosen by environment.
struct PlaidClient: Sendable {
    let clientId: String
    let secret: String
    let baseURL: String
    let transport: any PlaidTransport

    static func baseURL(for env: String) -> String {
        switch env {
        case "production": return "https://production.plaid.com"
        case "development": return "https://development.plaid.com"
        default: return "https://sandbox.plaid.com"
        }
    }

    /// `redirectUri` is what makes OAuth banks work. Most large US institutions
    /// (Chase, Wells Fargo, Capital One…) hand the user off to the bank's own
    /// app or site to authenticate, and Plaid needs a registered universal link
    /// to bring them back. Without it those institutions simply fail in Link
    /// while smaller ones keep working — a confusing partial failure, which is
    /// why this is wired up before it is needed rather than after.
    func createLinkToken(clientUserId: String, clientName: String,
                         products: [String], webhook: String?,
                         redirectUri: String? = nil) async throws -> PlaidLinkTokenCreateResponse {
        try await call("/link/token/create", PlaidLinkTokenCreateRequest(
            clientId: clientId, secret: secret, clientName: clientName,
            language: "en", countryCodes: ["US"],
            user: .init(clientUserId: clientUserId),
            products: products, webhook: webhook, redirectUri: redirectUri))
    }

    func exchangePublicToken(_ publicToken: String) async throws -> PlaidExchangeResponse {
        try await call("/item/public_token/exchange", PlaidExchangeRequest(
            clientId: clientId, secret: secret, publicToken: publicToken))
    }

    /// `/accounts/get`, deliberately, not `/accounts/balance/get`.
    ///
    /// They return the same shape; the difference is that
    /// `/accounts/balance/get` forces a live fetch from the bank and Plaid
    /// bills a flat fee for **every successful call**, while `/accounts/get`
    /// serves Plaid's cached balances and is free with Transactions. The
    /// nightly `sync-all` calls this once per item and then immediately runs
    /// `/transactions/sync` on the same item, which refreshes that cache
    /// anyway — so the paid endpoint was buying a few hours' freshness, per
    /// item, per night, forever.
    ///
    /// Budgets and net worth do not need to-the-second balances. If some future
    /// feature does (paying a bill against a live balance, say), call the
    /// real-time endpoint there specifically rather than making every sync pay
    /// for it.
    func getAccounts(accessToken: String) async throws -> PlaidAccountsResponse {
        try await call("/accounts/get", PlaidAccessTokenRequest(
            clientId: clientId, secret: secret, accessToken: accessToken))
    }

    func transactionsSync(accessToken: String, cursor: String?) async throws -> PlaidTransactionsSyncResponse {
        try await call("/transactions/sync", PlaidTransactionsSyncRequest(
            clientId: clientId, secret: secret, accessToken: accessToken, cursor: cursor, count: 500))
    }

    /// Sandbox-only: mint a public token for a test institution without the
    /// Link UI. Used by the dev "link sandbox account" path and tests.
    func sandboxCreatePublicToken(institutionId: String,
                                  products: [String]) async throws -> PlaidSandboxPublicTokenResponse {
        try await call("/sandbox/public_token/create", PlaidSandboxPublicTokenRequest(
            clientId: clientId, secret: secret, institutionId: institutionId, initialProducts: products))
    }

    /// Webhook verification: fetch the JWK for a key id. Returned as the raw
    /// response JSON (`{"key": {...JWK...}}`) so the verifier can hand the JWK
    /// straight to JWTKit without this client knowing about JWT types.
    func webhookVerificationKey(keyID: String) async throws -> Data {
        struct KeyRequest: Encodable {
            let clientId: String
            let secret: String
            let keyId: String
        }
        guard let url = URL(string: baseURL + "/webhook_verification_key/get") else {
            throw PlaidError.badURL
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(KeyRequest(clientId: clientId, secret: secret, keyId: keyID))
        let (data, status) = try await transport.post(url: url, json: body)
        guard (200..<300).contains(status) else {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let err = try? decoder.decode(PlaidErrorResponse.self, from: data)
            throw PlaidError.api(status: status, code: err?.errorCode,
                                 message: err?.errorMessage ?? "Plaid error \(status)")
        }
        return data
    }

    // MARK: - Core

    private func call<Req: Encodable, Res: Decodable>(_ path: String, _ body: Req) async throws -> Res {
        guard let url = URL(string: baseURL + path) else { throw PlaidError.badURL }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let (data, status) = try await transport.post(url: url, json: try encoder.encode(body))
        guard (200..<300).contains(status) else {
            let err = try? decoder.decode(PlaidErrorResponse.self, from: data)
            throw PlaidError.api(status: status, code: err?.errorCode,
                                 message: err?.errorMessage ?? err?.displayMessage ?? "Plaid error \(status)")
        }
        return try decoder.decode(Res.self, from: data)
    }
}

// MARK: - Application wiring

extension Application {
    private struct PlaidTransportKey: StorageKey { typealias Value = any PlaidTransport }

    /// Overridable in tests; defaults to the real URLSession transport.
    var plaidTransport: any PlaidTransport {
        get { storage[PlaidTransportKey.self] ?? URLSessionPlaidTransport() }
        set { storage[PlaidTransportKey.self] = newValue }
    }

    var plaid: PlaidClient {
        PlaidClient(clientId: appConfig.plaidClientID, secret: appConfig.plaidSecret,
                    baseURL: PlaidClient.baseURL(for: appConfig.plaidEnv),
                    transport: plaidTransport)
    }
}

extension Request {
    var plaid: PlaidClient { application.plaid }
}
