import Foundation
import Clibsodium

public enum CryptoError: LocalizedError {
    case initializationFailed
    case invalidKeyLength(String)
    case invalidKeyEncoding(String)
    case ciphertextTooShort
    case decryptionFailed(Int32)
    case invalidJSON
    case notEnrolled

    public var errorDescription: String? {
        switch self {
        case .initializationFailed:
            return "Failed to initialize libsodium"
        case .invalidKeyLength(let name):
            return "Invalid length for \(name): expected 32 bytes"
        case .invalidKeyEncoding(let name):
            return "Invalid base64url encoding for \(name)"
        case .ciphertextTooShort:
            return "Ciphertext is too short for a libsodium sealed box"
        case .decryptionFailed(let code):
            return "Decryption failed (libsodium code \(code))"
        case .invalidJSON:
            return "Decrypted plaintext is not valid JSON"
        case .notEnrolled:
            return "Device is not enrolled"
        }
    }
}

public final class SodiumCrypto: Sendable {
    public static let shared = SodiumCrypto()

    public init() {
        _ = Self.initializeSodium()
    }

    private static let initialized: Bool = {
        return sodium_init() >= 0
    }()

    public static func initializeSodium() -> Bool {
        return initialized
    }

    public func generateKeyPair() throws -> (publicKey: String, privateKey: String) {
        guard Self.initializeSodium() else { throw CryptoError.initializationFailed }

        var pk = [UInt8](repeating: 0, count: Int(crypto_box_publickeybytes()))
        var sk = [UInt8](repeating: 0, count: Int(crypto_box_secretkeybytes()))

        let result = crypto_box_keypair(&pk, &sk)
        guard result == 0 else { throw CryptoError.decryptionFailed(result) }

        defer {
            sodium_memzero(&sk, sk.count)
        }

        let pkB64 = Base64URL.encode(Data(pk))
        let skB64 = Base64URL.encode(Data(sk))
        return (publicKey: pkB64, privateKey: skB64)
    }

    public func openSealed(
        ciphertextB64: String,
        publicKeyB64: String,
        privateKeyB64: String
    ) throws -> [String: Any] {
        guard Self.initializeSodium() else { throw CryptoError.initializationFailed }

        guard let ctData = Base64URL.decode(ciphertextB64) else {
            throw CryptoError.invalidKeyEncoding("ciphertext")
        }
        guard let pkData = Base64URL.decode(publicKeyB64) else {
            throw CryptoError.invalidKeyEncoding("public_key")
        }
        guard pkData.count == crypto_box_publickeybytes() else {
            throw CryptoError.invalidKeyLength("public_key")
        }
        guard let skData = Base64URL.decode(privateKeyB64) else {
            throw CryptoError.invalidKeyEncoding("private_key")
        }
        guard skData.count == crypto_box_secretkeybytes() else {
            throw CryptoError.invalidKeyLength("private_key")
        }

        let sealBytes = crypto_box_sealbytes()
        guard ctData.count >= sealBytes else {
            throw CryptoError.ciphertextTooShort
        }

        let plainLen = ctData.count - sealBytes
        var plaintext = [UInt8](repeating: 0, count: plainLen)
        var skBytes = [UInt8](skData)
        defer {
            sodium_memzero(&skBytes, skBytes.count)
        }

        let result = ctData.withUnsafeBytes { ctPtr in
            pkData.withUnsafeBytes { pkPtr in
                skBytes.withUnsafeBytes { skPtr in
                    crypto_box_seal_open(
                        &plaintext,
                        ctPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        UInt64(ctData.count),
                        pkPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        skPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    )
                }
            }
        }

        guard result == 0 else {
            throw CryptoError.decryptionFailed(result)
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: Data(plaintext)),
              let dictionary = jsonObject as? [String: Any] else {
            throw CryptoError.invalidJSON
        }

        return dictionary
    }

    public func seal(message: Data, recipientPublicKeyB64: String) throws -> String {
        guard Self.initializeSodium() else { throw CryptoError.initializationFailed }

        guard let pkData = Base64URL.decode(recipientPublicKeyB64) else {
            throw CryptoError.invalidKeyEncoding("recipient public_key")
        }
        guard pkData.count == crypto_box_publickeybytes() else {
            throw CryptoError.invalidKeyLength("recipient public_key")
        }

        let cipherLen = message.count + crypto_box_sealbytes()
        var ciphertext = [UInt8](repeating: 0, count: cipherLen)

        let result = message.withUnsafeBytes { msgPtr in
            pkData.withUnsafeBytes { pkPtr in
                crypto_box_seal(
                    &ciphertext,
                    msgPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt64(message.count),
                    pkPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
            }
        }

        guard result == 0 else {
            throw CryptoError.decryptionFailed(result)
        }

        return Base64URL.encode(Data(ciphertext))
    }
}
