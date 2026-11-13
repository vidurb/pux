#include "test_harness.hpp"
#include "../src/storage/record_store.hpp"
#include "../src/storage/registration_outcome.hpp"
#include "../src/crypto/crypto.hpp"
#include <atomic>
#include "../src/vendor/qrcodegen.hpp"

namespace {

nlohmann::json make_valid_payload() {
    auto kp = pux::crypto::generate_key_pair();
    return {
        {"v", 1},
        {"record_id", "12345678-1234-1234-1234-123456789abc"},
        {"private_key", kp.private_key},
        {"public_key", kp.public_key},
        {"inbox", "relay-inbox@pux.vidur.xyz"},
        {"server", "https://pux.vidur.xyz"}
    };
}

} // namespace

TEST(record_store_parses_valid_qr) {
    auto mem_store = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::RecordStore rs(mem_store);

    auto valid_payload = make_valid_payload();
    std::string raw_json = valid_payload.dump();

    auto parsed = rs.parse_qr(raw_json);
    ASSERT_EQ(parsed["v"].get<int>(), 1);
    ASSERT_EQ(parsed["record_id"].get<std::string>(), "12345678-1234-1234-1234-123456789abc");
    ASSERT_EQ(parsed["inbox"].get<std::string>(), "relay-inbox@pux.vidur.xyz");
}

TEST(record_store_rejects_invalid_qr) {
    auto mem_store = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::RecordStore rs(mem_store);

    // Not JSON
    ASSERT_THROWS(rs.parse_qr("not-json"), pux::storage::ValidationException);

    // Unsupported version
    auto payload_v2 = make_valid_payload();
    payload_v2["v"] = 2;
    ASSERT_THROWS(rs.parse_qr(payload_v2.dump()), pux::storage::ValidationException);

    // Missing field
    auto payload_no_inbox = make_valid_payload();
    payload_no_inbox.erase("inbox");
    ASSERT_THROWS(rs.parse_qr(payload_no_inbox.dump()), pux::storage::ValidationException);

    // Invalid UUID
    auto payload_bad_uuid = make_valid_payload();
    payload_bad_uuid["record_id"] = "not-a-uuid";
    ASSERT_THROWS(rs.parse_qr(payload_bad_uuid.dump()), pux::storage::ValidationException);

    // Invalid key length
    auto payload_bad_key = make_valid_payload();
    payload_bad_key["private_key"] = "c2hvcnQ=";
    ASSERT_THROWS(rs.parse_qr(payload_bad_key.dump()), pux::storage::ValidationException);
}

TEST(record_store_validates_server_url) {
    // Valid HTTPS URLs
    ASSERT_EQ(
        pux::storage::RecordStore::validate_server_url("https://pux.vidur.xyz"),
        "https://pux.vidur.xyz"
    );
    ASSERT_EQ(
        pux::storage::RecordStore::validate_server_url("https://pux.vidur.xyz/"),
        "https://pux.vidur.xyz"
    );
    ASSERT_EQ(
        pux::storage::RecordStore::validate_server_url("https://custom.server.com:8443/"),
        "https://custom.server.com:8443"
    );

    // Local cleartext HTTP allowed
    ASSERT_EQ(
        pux::storage::RecordStore::validate_server_url("http://localhost:4000"),
        "http://localhost:4000"
    );
    ASSERT_EQ(
        pux::storage::RecordStore::validate_server_url("http://127.0.0.1:4000"),
        "http://127.0.0.1:4000"
    );
    ASSERT_EQ(
        pux::storage::RecordStore::validate_server_url("http://10.0.2.2:4000"),
        "http://10.0.2.2:4000"
    );

    // Remote cleartext HTTP refused
    ASSERT_THROWS(
        pux::storage::RecordStore::validate_server_url("http://insecure.example.com"),
        pux::storage::ValidationException
    );

    // Paths refused
    ASSERT_THROWS(
        pux::storage::RecordStore::validate_server_url("https://example.com/api"),
        pux::storage::ValidationException
    );

    // Query params refused
    ASSERT_THROWS(
        pux::storage::RecordStore::validate_server_url("https://example.com?foo=bar"),
        pux::storage::ValidationException
    );

    // Credentials refused
    ASSERT_THROWS(
        pux::storage::RecordStore::validate_server_url("https://user:pass@example.com"),
        pux::storage::ValidationException
    );

    ASSERT_EQ(
        pux::storage::RecordStore::validate_server_url("HTTPS://pux.vidur.xyz"),
        "https://pux.vidur.xyz"
    );

    ASSERT_THROWS(
        pux::storage::RecordStore::validate_server_url("https://example.com:"),
        pux::storage::ValidationException
    );
    ASSERT_THROWS(
        pux::storage::RecordStore::validate_server_url("https://example.com:abc"),
        pux::storage::ValidationException
    );
}

TEST(record_store_atomic_save_and_rollback) {
    class FailingSecretStore : public pux::storage::MemorySecretStore {
    public:
        void replace_all(std::map<std::string, std::string> data) override {
            if (data.count(pux::storage::RecordStore::kRecordIdKey) > 0) {
                throw pux::storage::StorageException("Simulated replace failure");
            }
            pux::storage::MemorySecretStore::replace_all(std::move(data));
        }
    };

    auto failing_store = std::make_shared<FailingSecretStore>();
    pux::storage::RecordStore rs(failing_store);

    auto valid_payload = make_valid_payload();

    ASSERT_THROWS(rs.save_enrollment(valid_payload), pux::storage::StorageException);

    ASSERT_FALSE(rs.is_enrolled());
    ASSERT_FALSE(rs.record_id().has_value());
    ASSERT_FALSE(rs.private_key().has_value());
    ASSERT_FALSE(rs.public_key().has_value());
    ASSERT_FALSE(rs.inbox().has_value());
}

TEST(record_store_desktop_device_id_persists) {
    auto mem_store = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::RecordStore rs(mem_store);

    std::string id1 = rs.desktop_device_id();
    ASSERT_EQ(id1.length(), 32);

    // Calling it again returns the same ID
    std::string id2 = rs.desktop_device_id();
    ASSERT_EQ(id1, id2);
}

TEST(record_store_clear_after_removal_applies_warning_in_single_replace) {
    class ReplaceCountStore : public pux::storage::MemorySecretStore {
    public:
        std::atomic<int> replace_calls{0};
        void replace_all(std::map<std::string, std::string> data) override {
            ++replace_calls;
            pux::storage::MemorySecretStore::replace_all(std::move(data));
        }
    };
    auto mem_store = std::make_shared<ReplaceCountStore>();
    pux::storage::RecordStore rs(mem_store);
    rs.save_enrollment(make_valid_payload());
    rs.save_notification_permission_asked();
    ASSERT_TRUE(rs.is_enrolled());
    mem_store->replace_calls = 0;
    rs.clear_after_removal(true);
    ASSERT_EQ(mem_store->replace_calls.load(), 1);
    ASSERT_FALSE(rs.is_enrolled());
    ASSERT_TRUE(rs.notification_permission_asked());
    ASSERT_TRUE(mem_store->read(pux::storage::kUncertainRegistrationKey).has_value());
    ASSERT_TRUE(mem_store->read(pux::storage::kRemovalRegistrationNoticeKey).has_value());
    ASSERT_FALSE(mem_store->read("record_id").has_value());
}

TEST(record_store_clear_preserves_notification_asked) {
    auto mem_store = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::RecordStore rs(mem_store);

    auto payload = make_valid_payload();
    rs.save_enrollment(payload);
    ASSERT_TRUE(rs.is_enrolled());

    rs.save_notification_permission_asked();
    ASSERT_TRUE(rs.notification_permission_asked());

    rs.clear();
    ASSERT_FALSE(rs.is_enrolled());
    ASSERT_TRUE(rs.notification_permission_asked());
}

TEST(record_store_qr_code_matrix_generation) {
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();

    auto store = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::RecordStore rs(store);

    nlohmann::json valid = {
        {"v", 1},
        {"record_id", "45678901-2345-6789-0123-456789012345"},
        {"private_key", kp.private_key},
        {"public_key", kp.public_key},
        {"inbox", "inbox@pux.example.com"},
        {"server", "https://relay.example.com"}
    };
    rs.save_enrollment(valid);

    auto payload = rs.enrollment_payload();
    std::string json_str = payload.dump();
    ASSERT_FALSE(json_str.empty());

    // Generate QR code
    auto qr = qrcodegen::QrCode::encodeText(json_str.c_str(), qrcodegen::QrCode::Ecc::LOW);

    // QR Code must have valid standard size (e.g. >= 21)
    ASSERT_TRUE(qr.getSize() >= 21);

    // Top-left finder pattern corner module (0,0) is always black (true)
    ASSERT_TRUE(qr.getModule(0, 0));
    // Top-left finder pattern white separator module (7,0) is white (false)
    ASSERT_FALSE(qr.getModule(7, 0));
}
