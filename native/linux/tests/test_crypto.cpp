#include "test_harness.hpp"
#include "../src/crypto/crypto.hpp"

namespace {

// Fixtures from the former Flutter crypto tests and server test vectors:
const char* kFixturePublicKey = "oVaRfoaaBI7h10MCUauxYiPWaLQaAjN_oklwaOO682M";
const char* kFixturePrivateKey = "3h7LhAw9e7EtYS5TeRJsQqYI8v4LtpH49buqnScv9qU";
const char* kFixtureCiphertext =
    "-h4t5FOku-OWtLBcg4jo8jCNDVhdUtGyVWDk4z_FmFAI46lEoMhWZkF76pcW6lcgJI9UJ8a8JQM-"
    "K3WA0vt7dXtlqXAKJwQfJ17REgKjSEVqOSjmmBpTmUcPtt_qHLCpMdk";

// Server PR typed payload fixture
const char* kServerPrPublicKey = "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw";
const char* kServerPrSecretKey = "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI";
const char* kServerPrCiphertext =
    "Xso7kEp1NhYtxtQC5hMfioNb2Q3_Y3KadFsVXxDtJRJ3KVUY_KqedKRIW-w4kMKf8SHpQ3FYbIJ7T8cM5LM-"
    "tCLJrk6Dyqe1J60Fu13SM6Ci1fISV_VAN9fI0WxPAdzUOBLSqhoVNlmvDg60KTX6k-ubO7gtRDmh8Jit8g3O"
    "MYhKV_KLn45FJKGjqF5ERXM6cmyCouvd2feDRw";

} // namespace

TEST(crypto_opens_server_sealed_box) {
    pux::crypto::init();
    nlohmann::json payload = pux::crypto::decrypt_payload(
        kFixtureCiphertext,
        kFixturePublicKey,
        kFixturePrivateKey
    );

    ASSERT_EQ(payload["type"].get<std::string>(), "otp");
    ASSERT_EQ(payload["otp"].get<std::string>(), "482913");
    ASSERT_EQ(payload["sender"].get<std::string>(), "HDFC Bank");
}

TEST(crypto_opens_typed_server_fixture) {
    pux::crypto::init();
    nlohmann::json payload = pux::crypto::decrypt_payload(
        kServerPrCiphertext,
        kServerPrPublicKey,
        kServerPrSecretKey
    );

    ASSERT_EQ(payload["type"].get<std::string>(), "otp");
    ASSERT_EQ(payload["otp"].get<std::string>(), "123456");
    ASSERT_EQ(payload["sender"].get<std::string>(), "Test Bank");
    ASSERT_EQ(payload["received_at"].get<std::string>(), "2026-10-06T00:00:00Z");
    ASSERT_EQ(payload["parser"].get<std::string>(), "generic");
}

TEST(crypto_rejects_wrong_key) {
    pux::crypto::init();
    auto other = pux::crypto::generate_key_pair();

    ASSERT_THROWS(
        pux::crypto::open_sealed_box(
            kFixtureCiphertext,
            other.public_key,
            other.private_key
        ),
        pux::crypto::DecryptionFailedException
    );
}

TEST(crypto_key_generation_and_roundtrip) {
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();

    // Check unpadded base64url (no '=')
    ASSERT_TRUE(kp.public_key.find('=') == std::string::npos);
    ASSERT_TRUE(kp.private_key.find('=') == std::string::npos);

    // Decoded keys must be 32 bytes
    ASSERT_EQ(pux::crypto::base64url_decode(kp.public_key).size(), 32);
    ASSERT_EQ(pux::crypto::base64url_decode(kp.private_key).size(), 32);

    std::string secret_msg = "{\"type\":\"otp\",\"otp\":\"999888\",\"sender\":\"ICICI Bank\"}";
    std::string ciphertext = pux::crypto::seal_box(secret_msg, kp.public_key);

    nlohmann::json decrypted = pux::crypto::decrypt_payload(ciphertext, kp.public_key, kp.private_key);
    ASSERT_EQ(decrypted["otp"].get<std::string>(), "999888");
    ASSERT_EQ(decrypted["sender"].get<std::string>(), "ICICI Bank");
}

TEST(crypto_rejects_malformed_ciphertext_and_keys) {
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();

    // Ciphertext too short (< 48 bytes sealed box overhead)
    ASSERT_THROWS(
        pux::crypto::open_sealed_box("AQIDBA==", kp.public_key, kp.private_key),
        pux::crypto::DecryptionFailedException
    );

    // Corrupted public key length
    ASSERT_THROWS(
        pux::crypto::open_sealed_box(kFixtureCiphertext, "AQIDBA==", kp.private_key),
        pux::crypto::InvalidKeyException
    );

    // Corrupted private key length
    ASSERT_THROWS(
        pux::crypto::open_sealed_box(kFixtureCiphertext, kp.public_key, "AQIDBA=="),
        pux::crypto::InvalidKeyException
    );

    // Invalid base64 character
    ASSERT_THROWS(
        pux::crypto::base64url_decode("Invalid!Base64*"),
        pux::crypto::CryptoException
    );
}
