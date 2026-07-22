import Foundation
import Crypto

/// Encrypts Plaid access tokens at rest with AES-GCM. The key is derived from
/// `PLAID_TOKEN_ENC_KEY` via SHA-256 so any-length secret yields a valid 32-byte
/// key. The stored value is base64(nonce ‖ ciphertext ‖ tag).
struct TokenCipher: Sendable {
    private let key: SymmetricKey

    init(secret: String) {
        self.key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
    }

    func encrypt(_ plaintext: String) throws -> String {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else {
            throw Abort_TokenCipher.sealFailed
        }
        return combined.base64EncodedString()
    }

    func decrypt(_ base64: String) throws -> String {
        guard let data = Data(base64Encoded: base64) else {
            throw Abort_TokenCipher.badCiphertext
        }
        let box = try AES.GCM.SealedBox(combined: data)
        let opened = try AES.GCM.open(box, using: key)
        return String(decoding: opened, as: UTF8.self)
    }
}

enum Abort_TokenCipher: Error { case sealFailed, badCiphertext }
