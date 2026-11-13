#pragma once

#include "../vendor/json.hpp"
#include <map>
#include <optional>
#include <regex>
#include <string>
#include <cctype>

namespace pux {
namespace storage {

// flutter_secure_storage_linux v3.0.3 account attribute for APPLICATION_ID xyz.vidur.pux
inline constexpr const char* kFssAccountAttribute = "xyz.vidur.pux.secureStorage";
inline constexpr const char* kFssItemLabel = "xyz.vidur.pux/FlutterSecureStorage";

inline bool is_valid_uuid(const std::string& str) {
    static const std::regex uuid_regex(
        "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        std::regex_constants::icase
    );
    return std::regex_match(str, uuid_regex);
}

enum class KeyringBlobKind {
    Missing,
    EmptyCleared,
    PreferenceOnly,
    PartialEnrollment,
    ValidEnrollment,
};

inline bool has_enrollment_identity_fields(const std::map<std::string, std::string>& data) {
    return data.find("record_id") != data.end() || data.find("private_key") != data.end() ||
           data.find("public_key") != data.end();
}

// True only for the JSON object shape FSS stores for a pux enrollment (strict).
inline bool looks_like_fss_enrollment(const std::map<std::string, std::string>& data) {
    if (data.empty()) return false;
    auto need = [&](const char* k) {
        auto it = data.find(k);
        return it != data.end() && !it->second.empty();
    };
    if (!need("record_id") || !need("private_key") || !need("public_key")) return false;
    if (!is_valid_uuid(data.at("record_id"))) return false;
    return true;
}

inline std::optional<std::map<std::string, std::string>> parse_keyring_json_object(const std::string& secret_data, bool& corrupt) {
    corrupt = false;
    std::map<std::string, std::string> result;
    if (secret_data.empty()) return result;
    try {
        auto j = nlohmann::json::parse(secret_data);
        if (!j.is_object()) {
            corrupt = true;
            return std::nullopt;
        }
        for (auto& item : j.items()) {
            if (item.value().is_string()) {
                result[item.key()] = item.value().get<std::string>();
            }
        }
        return result;
    } catch (...) {
        corrupt = true;
        return std::nullopt;
    }
}

inline KeyringBlobKind classify_keyring_blob(const std::string& secret_data, bool& corrupt) {
    corrupt = false;
    if (secret_data.empty()) {
        return KeyringBlobKind::Missing;
    }
    auto parsed = parse_keyring_json_object(secret_data, corrupt);
    if (corrupt || !parsed.has_value()) {
        return KeyringBlobKind::PartialEnrollment;
    }
    if (parsed->empty()) {
        return KeyringBlobKind::EmptyCleared;
    }
    if (looks_like_fss_enrollment(*parsed)) {
        return KeyringBlobKind::ValidEnrollment;
    }
    if (has_enrollment_identity_fields(*parsed)) {
        return KeyringBlobKind::PartialEnrollment;
    }
    return KeyringBlobKind::PreferenceOnly;
}

} // namespace storage
} // namespace pux
