import Foundation
import Vapor
import JWTKit
import Crypto

/// Verifies Plaid's `Plaid-Verification` header: an ES256 JWT whose claims
/// bind the exact request body (`request_body_sha256`) and issue time. The
/// public key is fetched per `kid` from `/webhook_verification_key/get` —
/// only Plaid can mint tokens our verification accepts, so a forged webhook
/// can't trigger syncs (or anything else) on this server.
struct PlaidWebhookVerifier: Sendable {
    let plaid: PlaidClient

    /// Reject tokens issued more than this long ago (Plaid's guidance: 5 min).
    static let maxAge: TimeInterval = 5 * 60

    struct Claims: JWTPayload {
        let iat: IssuedAtClaim
        let requestBodySha256: String

        enum CodingKeys: String, CodingKey {
            case iat
            case requestBodySha256 = "request_body_sha256"
        }

        // Structural checks (age, body hash) happen in `verify(token:rawBody:)`
        // where the raw body and clock are in hand.
        func verify(using _: some JWTAlgorithm) throws {}
    }

    enum VerifyError: Error, CustomStringConvertible {
        case malformedToken
        case wrongAlgorithm
        case stale
        case bodyMismatch

        var description: String {
            switch self {
            case .malformedToken: return "Plaid-Verification token is malformed"
            case .wrongAlgorithm: return "Plaid webhooks must be signed with ES256"
            case .stale: return "Plaid-Verification token is too old"
            case .bodyMismatch: return "Webhook body does not match the signed digest"
            }
        }
    }

    func verify(token: String, rawBody: Data, now: Date = Date()) async throws {
        // 1. Read alg + kid from the (unverified) header to pick the key.
        let header = try Self.peekHeader(token)
        guard header.alg == "ES256" else { throw VerifyError.wrongAlgorithm }
        guard let kid = header.kid else { throw VerifyError.malformedToken }

        // 2. Fetch Plaid's JWK for that kid and verify the signature.
        struct KeyEnvelope: Decodable { let key: JWK }
        let keyData = try await plaid.webhookVerificationKey(keyID: kid)
        let envelope = try JSONDecoder().decode(KeyEnvelope.self, from: keyData)
        let keys = JWTKeyCollection()
        try await keys.add(jwk: envelope.key)
        let claims = try await keys.verify(token, as: Claims.self)

        // 3. Freshness + exact body binding.
        guard now.timeIntervalSince(claims.iat.value) <= Self.maxAge else {
            throw VerifyError.stale
        }
        let digest = SHA256.hash(data: rawBody).map { String(format: "%02x", $0) }.joined()
        guard digest == claims.requestBodySha256.lowercased() else {
            throw VerifyError.bodyMismatch
        }
    }

    struct PeekedHeader: Decodable {
        let alg: String?
        let kid: String?
    }

    /// Decodes the JWT header segment WITHOUT verifying — used only to select
    /// the verification key; nothing is trusted until `keys.verify` passes.
    static func peekHeader(_ token: String) throws -> PeekedHeader {
        let segments = token.split(separator: ".")
        guard segments.count == 3,
              let data = Data(base64URLEncoded: String(segments[0])) else {
            throw VerifyError.malformedToken
        }
        return try JSONDecoder().decode(PeekedHeader.self, from: data)
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}
