#include "record_store.hpp"
#include "registration_outcome.hpp"
#include "../crypto/crypto.hpp"
#include <regex>
#include <sstream>
#include <cctype>
#include <iomanip>
#include <sodium.h>

namespace pux {
namespace storage {

const char* const RecordStore::kRecordIdKey = "record_id";
const char* const RecordStore::kPrivateKeyKey = "private_key";
const char* const RecordStore::kPublicKeyKey = "public_key";
const char* const RecordStore::kInboxKey = "inbox";
const char* const RecordStore::kServerKey = "server_url";
const char* const RecordStore::kDesktopDeviceIdKey = "desktop_device_id";
const char* const RecordStore::kDeviceIdKey = "device_id";
const char* const RecordStore::kNotificationPermissionAskedKey = "notification_permission_asked";

namespace {

const std::set<std::string> kCleartextHosts = {"localhost", "127.0.0.1", "10.0.2.2"};

bool is_valid_uuid(const std::string& str) {
    static const std::regex uuid_regex(
        "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        std::regex_constants::icase
    );
    return std::regex_match(str, uuid_regex);
}

} // namespace

RecordStore::RecordStore(
    std::shared_ptr<SecretStore> store,
    std::string default_server_url
) : store_(std::move(store)),
    default_server_url_(std::move(default_server_url)),
    server_url_(default_server_url_) {}

void RecordStore::init() {
    auto stored = store_->read(kServerKey);
    if (stored.has_value() && !stored->empty()) {
        server_url_ = stored.value();
    } else {
        server_url_ = default_server_url_;
    }
}

bool RecordStore::is_enrolled() {
    auto rid = store_->read(kRecordIdKey);
    auto priv = store_->read(kPrivateKeyKey);
    auto pub = store_->read(kPublicKeyKey);
    return rid.has_value() && !rid->empty() &&
           priv.has_value() && !priv->empty() &&
           pub.has_value() && !pub->empty();
}

std::string RecordStore::validate_server_url(const std::string& raw) {
    std::string str = raw;
    // Trim leading/trailing whitespace
    size_t first = str.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) {
        throw ValidationException("Invalid server URL in enrollment");
    }
    size_t last = str.find_last_not_of(" \t\r\n");
    str = str.substr(first, (last - first + 1));

    // Basic URL parsing
    std::string scheme;
    std::string rest;
    size_t scheme_pos = str.find("://");
    if (scheme_pos == std::string::npos) {
        throw ValidationException("Invalid server URL in enrollment");
    }
    scheme = str.substr(0, scheme_pos);
    for (char& c : scheme) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    rest = str.substr(scheme_pos + 3);

    // Disallow userinfo
    if (rest.find('@') != std::string::npos) {
        throw ValidationException("Server URL must not have a path, query or credentials");
    }
    // Disallow query or fragment
    if (rest.find('?') != std::string::npos || rest.find('#') != std::string::npos) {
        throw ValidationException("Server URL must not have a path, query or credentials");
    }

    std::string host_port;
    std::string path;
    size_t slash_pos = rest.find('/');
    if (slash_pos != std::string::npos) {
        host_port = rest.substr(0, slash_pos);
        path = rest.substr(slash_pos);
    } else {
        host_port = rest;
        path = "";
    }

    if (host_port.empty()) {
        throw ValidationException("Invalid server URL in enrollment");
    }

    // Path must not have length > 1 (e.g. only "/" allowed, which gets stripped)
    if (path.length() > 1) {
        throw ValidationException("Server URL must not have a path, query or credentials");
    }

    std::string host = host_port;
    std::string port_part;
    size_t colon_pos = host_port.find(':');
    if (colon_pos != std::string::npos) {
        host = host_port.substr(0, colon_pos);
        port_part = host_port.substr(colon_pos + 1);
        if (port_part.empty() || !std::all_of(port_part.begin(), port_part.end(), ::isdigit)) {
            throw ValidationException("Invalid server URL in enrollment");
        }
    }

    bool secure = (scheme == "https");
    bool local = (scheme == "http" && kCleartextHosts.find(host) != kCleartextHosts.end());

    if (!secure && !local) {
        throw ValidationException(
            "Refusing insecure server " + scheme + "://" + host + ": https is required"
        );
    }

    return scheme + "://" + host_port;
}

std::string RecordStore::enrollment_server(const nlohmann::json& payload) {
    if (!payload.contains("server") || payload["server"].is_null()) {
        return server_url_;
    }
    if (!payload["server"].is_string()) {
        throw ValidationException("Invalid server in enrollment");
    }
    std::string server = payload["server"].get<std::string>();
    if (server.empty()) {
        return server_url_;
    }
    if (server == default_server_url_) {
        return server;
    }
    return validate_server_url(server);
}

void RecordStore::validate_enrollment_payload(const nlohmann::json& payload) {
    if (!payload.contains("record_id") || !payload["record_id"].is_string()) {
        throw ValidationException("Invalid record_id in enrollment");
    }
    std::string record_id = payload["record_id"].get<std::string>();
    if (!is_valid_uuid(record_id)) {
        throw ValidationException("Invalid record_id in enrollment");
    }

    if (!payload.contains("inbox") || !payload["inbox"].is_string()) {
        throw ValidationException("Invalid inbox in enrollment");
    }

    if (!payload.contains("private_key") || !payload["private_key"].is_string()) {
        throw ValidationException("Missing private_key");
    }
    try {
        auto priv = crypto::base64url_decode(payload["private_key"].get<std::string>());
        if (priv.size() != 32) {
            throw ValidationException("Invalid private_key length");
        }
    } catch (const crypto::CryptoException&) {
        throw ValidationException("Invalid private_key encoding");
    }

    if (!payload.contains("public_key") || !payload["public_key"].is_string()) {
        throw ValidationException("Missing public_key");
    }
    try {
        auto pub = crypto::base64url_decode(payload["public_key"].get<std::string>());
        if (pub.size() != 32) {
            throw ValidationException("Invalid public_key length");
        }
    } catch (const crypto::CryptoException&) {
        throw ValidationException("Invalid public_key encoding");
    }

    enrollment_server(payload);
}

nlohmann::json RecordStore::parse_qr(const std::string& raw) {
    nlohmann::json payload;
    try {
        payload = nlohmann::json::parse(raw);
    } catch (...) {
        throw ValidationException("Invalid QR payload");
    }

    if (!payload.is_object()) {
        throw ValidationException("Invalid QR payload");
    }

    if (!payload.contains("v") || payload["v"] != 1) {
        throw ValidationException("Unsupported QR version");
    }

    for (const char* req : {"record_id", "private_key", "public_key", "inbox"}) {
        if (!payload.contains(req) || !payload[req].is_string() || payload[req].get<std::string>().empty()) {
            throw ValidationException(std::string("Missing ") + req + " in QR payload");
        }
    }

    validate_enrollment_payload(payload);
    return payload;
}

void RecordStore::save_enrollment(const nlohmann::json& payload) {
    validate_enrollment_payload(payload);
    std::string effective_server = enrollment_server(payload);

    std::map<std::string, std::string> data = store_->read_all();
    data[kInboxKey] = payload["inbox"].get<std::string>();
    data[kServerKey] = effective_server;
    data[kPublicKeyKey] = payload["public_key"].get<std::string>();
    data[kPrivateKeyKey] = payload["private_key"].get<std::string>();
    data[kRecordIdKey] = payload["record_id"].get<std::string>();
    store_->replace_all(std::move(data));

    server_url_ = effective_server;
}

std::optional<std::string> RecordStore::record_id() {
    return store_->read(kRecordIdKey);
}

std::optional<std::string> RecordStore::private_key() {
    return store_->read(kPrivateKeyKey);
}

std::optional<std::string> RecordStore::public_key() {
    return store_->read(kPublicKeyKey);
}

std::optional<std::string> RecordStore::inbox() {
    return store_->read(kInboxKey);
}

std::optional<std::string> RecordStore::device_id() {
    return store_->read(kDeviceIdKey);
}

void RecordStore::save_device_id(const std::string& device_id) {
    if (!device_id.empty()) {
        store_->write(kDeviceIdKey, device_id);
    }
}

std::string RecordStore::generate_desktop_device_id() {
    crypto::init();
    unsigned char random_bytes[16];
    randombytes_buf(random_bytes, sizeof(random_bytes));

    std::ostringstream oss;
    for (size_t i = 0; i < sizeof(random_bytes); ++i) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(random_bytes[i]);
    }
    return oss.str();
}

std::string RecordStore::desktop_device_id() {
    auto existing = store_->read(kDesktopDeviceIdKey);
    if (existing.has_value() && !existing->empty()) {
        return existing.value();
    }
    std::string gen = generate_desktop_device_id();
    store_->write(kDesktopDeviceIdKey, gen);
    return gen;
}

nlohmann::json RecordStore::enrollment_payload() {
    nlohmann::json j;
    j["v"] = 1;
    auto rid = record_id();
    auto priv = private_key();
    auto pub = public_key();
    auto inb = inbox();
    auto srv = store_->read(kServerKey);

    j["record_id"] = rid.has_value() ? rid.value() : "";
    j["private_key"] = priv.has_value() ? priv.value() : "";
    j["public_key"] = pub.has_value() ? pub.value() : "";
    j["inbox"] = inb.has_value() ? inb.value() : "";
    j["server"] = srv.has_value() && !srv->empty() ? srv.value() : server_url_;
    return j;
}

void RecordStore::clear_after_removal(bool retain_registration_warning) {
    std::map<std::string, std::string> retained;
    if (auto asked = store_->read(kNotificationPermissionAskedKey); asked && !asked->empty()) {
        retained[kNotificationPermissionAskedKey] = *asked;
    }
    if (retain_registration_warning) {
        retained[kUncertainRegistrationKey] = "1";
        retained[kRemovalRegistrationNoticeKey] = removal_registration_notice_text();
    }
    store_->replace_all(std::move(retained));
    server_url_ = default_server_url_;
}

void RecordStore::clear() {
    clear_after_removal(false);
}

bool RecordStore::notification_permission_asked() {
    auto val = store_->read(kNotificationPermissionAskedKey);
    return val.has_value() && val.value() == "true";
}

void RecordStore::save_notification_permission_asked() {
    store_->write(kNotificationPermissionAskedKey, "true");
}

} // namespace storage
} // namespace pux
