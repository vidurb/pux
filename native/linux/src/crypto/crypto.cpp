#include "crypto.hpp"
#include <sodium.h>
#include <cstring>

namespace pux {
namespace crypto {

namespace {

static const char kBase64UrlAlphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

} // namespace

void init() {
    static bool initialized = false;
    if (!initialized) {
        if (sodium_init() < 0) {
            throw CryptoException("Failed to initialize libsodium");
        }
        initialized = true;
    }
}

std::string base64url_encode(const uint8_t* data, size_t len) {
    std::string out;
    out.reserve(((len + 2) / 3) * 4);

    size_t i = 0;
    while (i < len) {
        size_t remaining = len - i;
        uint32_t octet_a = data[i++];
        uint32_t octet_b = (remaining > 1) ? data[i++] : 0;
        uint32_t octet_c = (remaining > 2) ? data[i++] : 0;

        uint32_t triple = (octet_a << 16) | (octet_b << 8) | octet_c;

        out.push_back(kBase64UrlAlphabet[(triple >> 18) & 0x3F]);
        out.push_back(kBase64UrlAlphabet[(triple >> 12) & 0x3F]);

        if (remaining > 1) {
            out.push_back(kBase64UrlAlphabet[(triple >> 6) & 0x3F]);
        }
        if (remaining > 2) {
            out.push_back(kBase64UrlAlphabet[triple & 0x3F]);
        }
    }

    return out;
}

std::string base64url_encode(const std::vector<uint8_t>& data) {
    return base64url_encode(data.data(), data.size());
}

std::string base64url_encode(const std::string& data) {
    return base64url_encode(reinterpret_cast<const uint8_t*>(data.data()), data.size());
}

static int decode_char(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-' || c == '+') return 62;
    if (c == '_' || c == '/') return 63;
    if (c == '=') return -2; // padding
    return -1; // invalid
}

std::vector<uint8_t> base64url_decode(const std::string& input) {
    std::vector<uint8_t> out;
    out.reserve((input.size() * 3) / 4);

    uint32_t buffer = 0;
    int bits_collected = 0;

    for (char c : input) {
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
        int val = decode_char(c);
        if (val == -2) {
            // padding encountered
            break;
        }
        if (val == -1) {
            throw CryptoException("Invalid character in base64url string");
        }

        buffer = (buffer << 6) | val;
        bits_collected += 6;

        if (bits_collected >= 8) {
            bits_collected -= 8;
            out.push_back(static_cast<uint8_t>((buffer >> bits_collected) & 0xFF));
        }
    }

    return out;
}

KeyPair generate_key_pair() {
    init();

    unsigned char pk[crypto_box_PUBLICKEYBYTES];
    unsigned char sk[crypto_box_SECRETKEYBYTES];

    if (crypto_box_keypair(pk, sk) != 0) {
        throw CryptoException("Failed to generate X25519 keypair");
    }

    KeyPair kp;
    kp.public_key = base64url_encode(pk, sizeof(pk));
    kp.private_key = base64url_encode(sk, sizeof(sk));

    // Zero out sensitive secret key memory
    sodium_memzero(sk, sizeof(sk));

    return kp;
}

std::vector<uint8_t> open_sealed_box(
    const std::string& ciphertext_b64,
    const std::string& public_key_b64,
    const std::string& private_key_b64
) {
    init();

    std::vector<uint8_t> ciphertext = base64url_decode(ciphertext_b64);
    std::vector<uint8_t> public_key = base64url_decode(public_key_b64);
    std::vector<uint8_t> private_key = base64url_decode(private_key_b64);

    if (public_key.size() != crypto_box_PUBLICKEYBYTES) {
        throw InvalidKeyException("Invalid public key length (must be 32 bytes)");
    }
    if (private_key.size() != crypto_box_SECRETKEYBYTES) {
        throw InvalidKeyException("Invalid private key length (must be 32 bytes)");
    }
    if (ciphertext.size() < crypto_box_SEALBYTES) {
        throw DecryptionFailedException("Ciphertext is too short for sealed box");
    }

    size_t plaintext_len = ciphertext.size() - crypto_box_SEALBYTES;
    std::vector<uint8_t> plaintext(plaintext_len);

    int res = crypto_box_seal_open(
        plaintext.data(),
        ciphertext.data(),
        ciphertext.size(),
        public_key.data(),
        private_key.data()
    );

    // Securely wipe secret key from memory
    sodium_memzero(private_key.data(), private_key.size());

    if (res != 0) {
        throw DecryptionFailedException("Failed to open sealed box (wrong key or corrupted ciphertext)");
    }

    return plaintext;
}

nlohmann::json decrypt_payload(
    const std::string& ciphertext_b64,
    const std::string& public_key_b64,
    const std::string& private_key_b64
) {
    std::vector<uint8_t> plaintext = open_sealed_box(
        ciphertext_b64,
        public_key_b64,
        private_key_b64
    );

    std::string json_str(plaintext.begin(), plaintext.end());
    try {
        return nlohmann::json::parse(json_str);
    } catch (const std::exception& e) {
        throw DecryptionFailedException(std::string("Decrypted payload is not valid JSON: ") + e.what());
    }
}

std::string seal_box(
    const uint8_t* message,
    size_t len,
    const std::string& public_key_b64
) {
    init();

    std::vector<uint8_t> public_key = base64url_decode(public_key_b64);
    if (public_key.size() != crypto_box_PUBLICKEYBYTES) {
        throw InvalidKeyException("Invalid public key length (must be 32 bytes)");
    }

    size_t clen = len + crypto_box_SEALBYTES;
    std::vector<uint8_t> ciphertext(clen);

    if (crypto_box_seal(ciphertext.data(), message, len, public_key.data()) != 0) {
        throw CryptoException("Failed to seal box");
    }

    return base64url_encode(ciphertext);
}

std::string seal_box(
    const std::string& message,
    const std::string& public_key_b64
) {
    return seal_box(
        reinterpret_cast<const uint8_t*>(message.data()),
        message.size(),
        public_key_b64
    );
}

} // namespace crypto
} // namespace pux
