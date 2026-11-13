#pragma once

#include <string>
#include <memory>
#include <optional>
#include <set>
#include <stdexcept>
#include "../vendor/json.hpp"
#include "secret_store.hpp"

namespace pux {
namespace storage {

class ValidationException : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class RecordStore {
public:
    static const char* const kRecordIdKey;
    static const char* const kPrivateKeyKey;
    static const char* const kPublicKeyKey;
    static const char* const kInboxKey;
    static const char* const kServerKey;
    static const char* const kDesktopDeviceIdKey;
    static const char* const kDeviceIdKey;
    static const char* const kNotificationPermissionAskedKey;

    explicit RecordStore(
        std::shared_ptr<SecretStore> store,
        std::string default_server_url = "https://pux.vidur.xyz"
    );

    void init();

    const std::string& server_url() const { return server_url_; }
    void set_server_url(std::string url) { server_url_ = std::move(url); }
    const std::string& default_server_url() const { return default_server_url_; }

    bool is_enrolled();

    // Parse and validate enrollment QR / JSON string
    nlohmann::json parse_qr(const std::string& raw);

    // Validate server URL according to security specification
    static std::string validate_server_url(const std::string& raw);

    // Resolve effective server from enrollment payload
    std::string enrollment_server(const nlohmann::json& payload);

    // Save enrollment payload with atomic partial-write protection
    void save_enrollment(const nlohmann::json& payload);

    std::optional<std::string> record_id();
    std::optional<std::string> private_key();
    std::optional<std::string> public_key();
    std::optional<std::string> inbox();

    // Server-returned device registration ID
    std::optional<std::string> device_id();
    void save_device_id(const std::string& device_id);

    // Unique desktop installation token (16 random hex bytes)
    std::string desktop_device_id();

    // Export enrollment payload
    nlohmann::json enrollment_payload();

    // Forget enrollment locally, preserving notificationPermissionAsked
    void clear();
    void clear_after_removal(bool retain_registration_warning);

    bool notification_permission_asked();
    void save_notification_permission_asked();

    std::shared_ptr<SecretStore> secret_store() const { return store_; }

private:
    std::shared_ptr<SecretStore> store_;
    std::string default_server_url_;
    std::string server_url_;

    void validate_enrollment_payload(const nlohmann::json& payload);
    std::string generate_desktop_device_id();
};

} // namespace storage
} // namespace pux
