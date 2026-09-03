import Testing
import Foundation
import Vapor
@testable import App

/// Plaid OAuth wiring. Large US banks hand the user to their own app to
/// authenticate and Plaid returns them via a registered universal link, so
/// `/link/token/create` has to carry a `redirect_uri`. The subtle half is that
/// it must be *absent*, not empty, when unconfigured: Plaid rejects a redirect
/// URI that isn't registered for the environment, so sending "" would break
/// sandbox linking entirely.
@Suite("Plaid OAuth redirect")
struct PlaidOAuthTests {

    /// Captures the request body so the test can assert on the wire format,
    /// which is the thing Plaid actually sees.
    actor BodyCapturingTransport: PlaidTransport {
        private(set) var lastBody: [String: Any] = [:]

        func post(url: URL, json: Data) async throws -> (data: Data, status: Int) {
            lastBody = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
            return (Data(#"{"link_token":"link-abc","expiration":null}"#.utf8), 200)
        }
    }

    private func linkToken(redirectUri: String?) async throws -> [String: Any] {
        let transport = BodyCapturingTransport()
        let client = PlaidClient(clientId: "id", secret: "secret",
                                 baseURL: "https://sandbox.plaid.com", transport: transport)
        _ = try await client.createLinkToken(
            clientUserId: "user-1", clientName: "Budget",
            products: ["transactions"], webhook: "https://example.com/hook",
            redirectUri: redirectUri)
        return await transport.lastBody
    }

    @Test("A configured redirect URI is sent as snake_case redirect_uri")
    func sendsRedirectURI() async throws {
        let body = try await linkToken(redirectUri: "https://mbandhb.com/plaid-oauth")
        #expect(body["redirect_uri"] as? String == "https://mbandhb.com/plaid-oauth")
        // Sanity: the rest of the payload still encodes the way Plaid expects.
        #expect(body["client_name"] as? String == "Budget")
        #expect((body["user"] as? [String: Any])?["client_user_id"] as? String == "user-1")
    }

    @Test("With no redirect URI the key is omitted entirely, not sent empty")
    func omitsRedirectURIWhenUnset() async throws {
        let body = try await linkToken(redirectUri: nil)
        #expect(body["redirect_uri"] == nil)
        #expect(body["webhook"] as? String == "https://example.com/hook")
    }
}
