#pragma once

#include <string>
#include <vector>
#include <cstdint>
#include <stdexcept>
#include "../vendor/json.hpp"

namespace pux {
namespace crypto {

class CryptoException : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class InvalidKeyException : public CryptoException {
public:
    using CryptoException::CryptoException;
};

class DecryptionFailedException : public CryptoException {
public:
    using CryptoException::CryptoException;
};

struct KeyPair {
    std::string public_key;  // 32 bytes, unpadded base64url
    std::string private_key; // 32 bytes, unpadded base64url
};

// Initialize libsodium. Safe to call multiple times.
void init();

// Base64url encoding (unpadded, RFC 4648 §5)
std::string base64url_encode(const uint8_t* data, size_t len);
std::string base64url_encode(const std::vector<uint8_t>& data);
std::string base64url_encode(const std::string& data);

// Base64url decoding (accepts padded or unpadded, RFC 4648 §5)
std::vector<uint8_t> base64url_decode(const std::string& input);

// Generate an X25519 keypair for libsodium sealed boxes
KeyPair generate_key_pair();

// Open a libsodium sealed box (:enacl.box_seal / crypto_box_seal)
// Decrypts ciphertext with recipient's public and private keys.
// Returns the plaintext bytes.
std::vector<uint8_t> open_sealed_box(
    const std::string& ciphertext_b64,
    const std::string& public_key_b64,
    const std::string& private_key_b64
);

// Open a sealed box and parse the plaintext as JSON
nlohmann::json decrypt_payload(
    const std::string& ciphertext_b64,
    const std::string& public_key_b64,
    const std::string& private_key_b64
);

// Encrypt a message into a libsodium sealed box using the recipient's public key.
// Returns unpadded base64url ciphertext.
std::string seal_box(
    const uint8_t* message,
    size_t len,
    const std::string& public_key_b64
);
std::string seal_box(
    const std::string& message,
    const std::string& public_key_b64
);

} // namespace crypto
} // namespace pux
