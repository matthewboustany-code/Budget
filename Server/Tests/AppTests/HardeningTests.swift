import Testing
import Foundation
import Vapor
import JWTKit
import Crypto
@testable import App

/// P7 hardening: production config fail-fast and Plaid webhook signature
/// verification. Config rules are tested through `AppConfig.validate` (not
/// `load`) so no test touches process environment variables — those race
/// across parallel suites.
@Suite("Hardening")
struct HardeningTests {

    // MARK: - Config fail-fast

    private func config(jwtSecret: String = String(repeating: "a", count: 40),
                        encKey: String = "3fb2…realish-key") -> AppConfig {
        AppConfig(appleBundleID: "Me.Budget", sessionJWTSecret: jwtSecret,
                  plaidClientID: "id", plaidSecret: "secret", plaidEnv: "production",
                  plaidProducts: ["transactions"], plaidWebhookURL: nil,
                  plaidTokenEncKey: encKey, authDevMode: false)
    }

    @Test("Production refuses placeholder or short secrets and dev mode")
    func productionValidation() throws {
        // A properly configured production environment passes.
        try AppConfig.validate(config(), env: .production, devModeRequested: nil)

        #expect(throws: AppConfig.ConfigError.self) {
            try AppConfig.validate(config(jwtSecret: "dev-insecure-secret-change-me"),
                                   env: .production, devModeRequested: nil)
        }
        #expect(throws: AppConfig.ConfigError.self) {
            try AppConfig.validate(config(jwtSecret: "short"),
                                   env: .production, devModeRequested: nil)
        }
        #expect(throws: AppConfig.ConfigError.self) {
            try AppConfig.validate(config(encKey: ""),
                                   env: .production, devModeRequested: nil)
        }
        #expect(throws: AppConfig.ConfigError.self) {
            try AppConfig.validate(config(encKey: "change-me-to-32-bytes-hex"),
                                   env: .production, devModeRequested: nil)
        }
        #expect(throws: AppConfig.ConfigError.self) {
            try AppConfig.validate(config(), env: .production, devModeRequested: true)
        }
    }

    @Test("Development keeps its permissive defaults")
    func developmentValidation() throws {
        try AppConfig.validate(config(jwtSecret: "dev-insecure-secret-change-me", encKey: ""),
                               env: .development, devModeRequested: true)
    }

    // MARK: - Webhook verification

    /// Transport that answers `/webhook_verification_key/get` with the JWK for
    /// a locally generated ES256 key — the test plays the role of Plaid.
    struct KeyServingTransport: PlaidTransport {
        let jwkJSON: String
        func post(url: URL, json: Data) async throws -> (data: Data, status: Int) {
            guard url.path == "/webhook_verification_key/get" else { return (Data("{}".utf8), 404) }
            return (Data(#"{"key":\#(jwkJSON)}"#.utf8), 200)
        }
    }

    private struct Signer {
        let keys: JWTKeyCollection
        let verifier: PlaidWebhookVerifier

        init() async throws {
            let privateKey = try ES256PrivateKey()
            let params = privateKey.publicKey.parameters!
            let jwk = """
            {"kty":"EC","use":"sig","crv":"P-256","kid":"test-kid","alg":"ES256",\
            "x":"\(params.x)","y":"\(params.y)"}
            """
            let keys = JWTKeyCollection()
            await keys.add(ecdsa: privateKey, kid: "test-kid")
            self.keys = keys
            self.verifier = PlaidWebhookVerifier(plaid: PlaidClient(
                clientId: "id", secret: "secret", baseURL: "https://sandbox.plaid.com",
                transport: KeyServingTransport(jwkJSON: jwk)))
        }

        func token(for body: Data, issuedAt: Date = Date()) async throws -> String {
            let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            let claims = PlaidWebhookVerifier.Claims(iat: .init(value: issuedAt),
                                                    requestBodySha256: digest)
            return try await keys.sign(claims, kid: "test-kid")
        }
    }

    @Test("A correctly signed webhook verifies")
    func signedWebhookVerifies() async throws {
        let signer = try await Signer()
        let body = Data(#"{"webhook_type":"TRANSACTIONS","item_id":"item-123"}"#.utf8)
        try await signer.verifier.verify(token: signer.token(for: body), rawBody: body)
    }

    @Test("A tampered body is rejected")
    func tamperedBodyRejected() async throws {
        let signer = try await Signer()
        let body = Data(#"{"webhook_type":"TRANSACTIONS","item_id":"item-123"}"#.utf8)
        let token = try await signer.token(for: body)
        let tampered = Data(#"{"webhook_type":"TRANSACTIONS","item_id":"item-EVIL"}"#.utf8)
        await #expect(throws: PlaidWebhookVerifier.VerifyError.bodyMismatch) {
            try await signer.verifier.verify(token: token, rawBody: tampered)
        }
    }

    @Test("A stale token is rejected")
    func staleTokenRejected() async throws {
        let signer = try await Signer()
        let body = Data("{}".utf8)
        let old = Date().addingTimeInterval(-3600)
        let token = try await signer.token(for: body, issuedAt: old)
        await #expect(throws: PlaidWebhookVerifier.VerifyError.stale) {
            try await signer.verifier.verify(token: token, rawBody: body)
        }
    }

    @Test("Garbage and wrong-algorithm tokens are rejected")
    func malformedTokensRejected() async throws {
        let signer = try await Signer()
        await #expect(throws: PlaidWebhookVerifier.VerifyError.self) {
            try await signer.verifier.verify(token: "not-a-jwt", rawBody: Data())
        }
        // HS256-signed token (attacker without Plaid's private key).
        let hmacKeys = JWTKeyCollection()
        await hmacKeys.add(hmac: "attacker-key", digestAlgorithm: .sha256)
        let digest = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let forged = try await hmacKeys.sign(
            PlaidWebhookVerifier.Claims(iat: .init(value: Date()), requestBodySha256: digest))
        await #expect(throws: PlaidWebhookVerifier.VerifyError.wrongAlgorithm) {
            try await signer.verifier.verify(token: forged, rawBody: Data())
        }
    }
}
