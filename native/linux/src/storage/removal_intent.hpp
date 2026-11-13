#pragma once
#include "record_store.hpp"
#include "registration_outcome.hpp"
#include "../api/api_client.hpp"

namespace pux::storage {
inline constexpr const char* kRemovalIntentKey = "native_linux_removal_intent";

struct RemovalIntent {
    std::string action; // device, relay, or local
    std::string record_id;
    std::string device_id;
    bool warn_uncertain_registration = false;
};

inline RemovalIntent parse_removal_intent(const nlohmann::json& value) {
    RemovalIntent intent{
        value.at("action").get<std::string>(),
        value.at("record_id").get<std::string>(),
        value.at("device_id").get<std::string>(),
    };
    if (value.contains("warn_uncertain_registration") && value.at("warn_uncertain_registration").is_boolean()) {
        intent.warn_uncertain_registration = value.at("warn_uncertain_registration").get<bool>();
    }
    return intent;
}

inline void persist_removal_intent(RecordStore& store, const RemovalIntent& intent) {
    nlohmann::json marker = {
        {"action", intent.action},
        {"record_id", intent.record_id},
        {"device_id", intent.device_id},
        {"server", store.server_url()},
    };
    if (intent.warn_uncertain_registration) {
        marker["warn_uncertain_registration"] = true;
    }
    store.secret_store()->write(kRemovalIntentKey, marker.dump());
}

inline bool retain_registration_warning_for_intent(const RemovalIntent& intent) {
    return intent.action == "device" && intent.warn_uncertain_registration;
}

inline void finish_local_removal_state(RecordStore& store, const RemovalIntent& intent) {
    store.clear_after_removal(retain_registration_warning_for_intent(intent));
}

// The marker is committed before any remote request and encodes any durable warning.
inline void complete_removal(RecordStore& store, api::ApiClient& api, const RemovalIntent& intent, bool persist) {
    auto record = store.record_id();
    if (!record || *record != intent.record_id || intent.record_id.empty())
        throw StorageException("Pending removal does not match the stored relay");
    if (intent.action != "device" && intent.action != "relay" && intent.action != "local")
        throw StorageException("Invalid pending removal action");
    if (persist) persist_removal_intent(store, intent);
    if (intent.action == "device") {
        std::string device_id;
        if (auto stored = store.device_id(); stored && !stored->empty()) {
            device_id = *stored;
        } else if (!intent.device_id.empty()) {
            device_id = intent.device_id;
        }
        if (device_id.empty()) {
            finish_local_removal_state(store, intent);
            return;
        }
        RemovalIntent durable_intent = intent;
        durable_intent.device_id = device_id;
        if (persist) {
            persist_removal_intent(store, durable_intent);
        }
        try {
            api.delete_device(store.server_url(), intent.record_id, device_id);
        } catch (const api::RecordNotFoundException&) {
            finish_local_removal_state(store, intent);
            return;
        }
    } else if (intent.action == "relay") {
        api.delete_record(store.server_url(), intent.record_id);
    }
    finish_local_removal_state(store, intent);
}

inline void recover_removal(RecordStore& store, api::ApiClient& api) {
    auto marker = store.secret_store()->read(kRemovalIntentKey);
    if (!marker) return;
    RemovalIntent intent;
    try {
        auto value = nlohmann::json::parse(*marker);
        if (value.at("server").get<std::string>() != store.server_url())
            throw StorageException("Pending removal server does not match stored enrollment");
        intent = parse_removal_intent(value);
    } catch (const StorageException&) {
        throw;
    } catch (...) {
        throw StorageException("Invalid pending removal or server mismatch; keyring was not changed");
    }
    complete_removal(store, api, intent, false);
}

// Explicit user choice: abandon the remote retry, but retain a local-only
// intent until the keyring has actually been cleared.
inline void forget_pending_locally(RecordStore& store) {
    if (!store.secret_store()->read(kRemovalIntentKey))
        throw StorageException("No pending removal was found; nothing was changed");
    auto record = store.record_id();
    if (!record || record->empty())
        throw StorageException("The relay ID is unavailable; keyring was not changed");
    persist_removal_intent(store, {"local", *record, "", false});
    store.clear();
}
}