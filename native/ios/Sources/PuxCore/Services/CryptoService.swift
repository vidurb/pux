import Foundation
import Sodium

public final class CryptoService {
    public static let shared = CryptoService()

    private let sodium: Sodium

    public init(sodium: Sodium = Sodium()) {
        self.sodium = sodium
    }

    /// Generates a Curve25519 keypair for sealed boxes, returning unpadded base64url keys.
    public func generateKeyPair() throws -> (publicKey: String, privateKey: String) {
        guard let keyPair = sodium.box.keyPair() else {
            throw PuxError.cryptoInitFailed
        }
        var secret = keyPair.secretKey
        defer { sodium.utils.zero(&secret) }

        let pubB64 = Base64URL.encode(Data(keyPair.publicKey))
        let privB64 = Base64URL.encode(Data(secret))
        return (publicKey: pubB64, privateKey: privB64)
    }

    /// Opens a libsodium sealed box (:enacl.box_seal) with unpadded base64url keys and ciphertext.
    public func openSealed(
        ciphertextB64: String,
        publicKeyB64: String,
        privateKeyB64: String
    ) throws -> [String: Any] {
        guard let cipherData = Base64URL.decode(ciphertextB64) else {
            throw PuxError.invalidKeyEncoding("ciphertext")
        }
        let pubData = try Base64URL.decodeKey(publicKeyB64, fieldName: "public_key")
        let privData = try Base64URL.decodeKey(privateKeyB64, fieldName: "private_key")

        var secretBytes = Bytes(privData)
        defer { sodium.utils.zero(&secretBytes) }

        guard let plaintext = sodium.box.open(
            anonymousCipherText: Bytes(cipherData),
            recipientPublicKey: Bytes(pubData),
            recipientSecretKey: secretBytes
        ) else {
            throw PuxError.undecryptablePayload
        }

        let data = Data(plaintext)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PuxError.undecryptablePayload
        }
        return json
    }

    /// Seals a message into a libsodium sealed box, encoded as unpadded base64url.
    public func seal(message: Data, recipientPublicKeyB64: String) throws -> String {
        let pubData = try Base64URL.decodeKey(recipientPublicKeyB64, fieldName: "public_key")
        guard let sealed = sodium.box.seal(
            message: Bytes(message),
            recipientPublicKey: Bytes(pubData)
        ) else {
            throw PuxError.cryptoInitFailed
        }
        return Base64URL.encode(Data(sealed))
    }
}
