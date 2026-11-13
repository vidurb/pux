#include "secret_store.hpp"
#include "secret_store_keyring_probe.hpp"
#include "fss_keyring_compat.hpp"
#include "../vendor/json.hpp"

#include <gio/gio.h>
#include <iostream>
#include <cstring>
#include <vector>

#ifdef HAVE_LIBSECRET
#include <libsecret/secret.h>
#endif

namespace pux {
namespace storage {

namespace {

#ifdef HAVE_LIBSECRET
constexpr const char* kNativeSchemaName = "default";

// Matches flutter_secure_storage_linux store path (schema name "default" when not corrupted).
static const SecretSchema kFssSchema = {
    kNativeSchemaName,
    SECRET_SCHEMA_NONE,
    {
        {"account", SECRET_SCHEMA_ATTRIBUTE_STRING},
        {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING}
    }
};

GHashTable* build_account_attributes(const std::string& account_attribute) {
    return secret_attributes_build(&kFssSchema, "account", account_attribute.c_str(), nullptr);
}

bool schema_is_native(const char* schema) {
    return schema && strcmp(schema, kNativeSchemaName) == 0;
}

bool label_matches_item(SecretItem* item, const std::string& item_label) {
    const char* label = secret_item_get_label(item);
    return label && strcmp(label, item_label.c_str()) == 0;
}

bool is_legacy_labeled_item(SecretItem* item, const std::string& item_label) {
    if (schema_is_native(secret_item_get_schema_name(item))) {
        return false;
    }
    return label_matches_item(item, item_label);
}

std::optional<std::string> load_item_secret_text(SecretItem* item, GError** err) {
    if (!secret_item_load_secret_sync(item, nullptr, err)) {
        return std::nullopt;
    }
    SecretValue* value = secret_item_get_secret(item);
    if (!value) {
        return std::nullopt;
    }
    gsize length = 0;
    const gchar* text = secret_value_get(value, &length);
    std::optional<std::string> out;
    if (text && length > 0) {
        out.emplace(text, length);
    }
    secret_value_unref(value);
    return out;
}

GList* search_account_items(SecretService* service, const std::string& account_attribute, GError** err) {
    GHashTable* attrs = build_account_attributes(account_attribute);
    GList* items = secret_service_search_sync(
        service, nullptr, attrs, SECRET_SEARCH_ALL, nullptr, err);
    g_hash_table_unref(attrs);
    return items;
}

void release_item_refs(std::vector<SecretItem*>& refs) {
    for (auto* item : refs) {
        g_object_unref(item);
    }
    refs.clear();
}

[[noreturn]] void throw_keyring_io_error(GError* err, const char* context) {
    if (err && g_error_matches(err, SECRET_ERROR, SECRET_ERROR_IS_LOCKED)) {
        g_error_free(err);
        throw KeyringLockedException();
    }
    std::string msg = context;
    if (err && err->message) {
        msg += ": ";
        msg += err->message;
    }
    if (err) {
        g_error_free(err);
    }
    throw StorageException(msg);
}

void ensure_keyring_unlocked_for_account(
    const std::string& account_attribute,
    const std::string& item_label
) {
    GError* err = nullptr;
    SecretService* service = secret_service_get_sync(SECRET_SERVICE_OPEN_SESSION, nullptr, &err);
    if (!service) {
        throw_keyring_io_error(err, "Secret Service unavailable");
    }

    auto throw_if_locked_alias = [&](const char* alias) {
        SecretCollection* collection =
            secret_collection_for_alias_sync(service, alias, SECRET_COLLECTION_NONE, nullptr, &err);
        if (err) {
            throw_keyring_io_error(err, "Secret Service collection lookup failed");
        }
        if (!collection) {
            return;
        }
        const gboolean locked = secret_collection_get_locked(collection);
        g_object_unref(collection);
        if (locked) {
            g_object_unref(service);
            throw KeyringLockedException();
        }
    };
    throw_if_locked_alias(SECRET_COLLECTION_DEFAULT);
    throw_if_locked_alias("login");

    GList* items = search_account_items(service, account_attribute, &err);
    g_object_unref(service);
    if (err) {
        throw_keyring_io_error(err, "Secret Service search failed");
    }
    if (!items) {
        return;
    }
    for (GList* node = items; node != nullptr; node = node->next) {
        auto* item = SECRET_ITEM(node->data);
        if (!label_matches_item(item, item_label)) {
            continue;
        }
        if (secret_item_get_locked(item)) {
            g_list_free_full(items, g_object_unref);
            throw KeyringLockedException();
        }
    }
    g_list_free_full(items, g_object_unref);
}

std::vector<SecretItem*> collect_legacy_item_refs(
    const std::string& account_attribute,
    const std::string& item_label
) {
    GError* err = nullptr;
    std::vector<SecretItem*> refs;
    SecretService* service = secret_service_get_sync(SECRET_SERVICE_OPEN_SESSION, nullptr, &err);
    if (!service) {
        throw_keyring_io_error(err, "Secret Service unavailable");
    }
    GList* items = search_account_items(service, account_attribute, &err);
    g_object_unref(service);
    if (err) {
        throw_keyring_io_error(err, "Secret Service search failed");
    }
    if (!items) {
        return refs;
    }
    for (GList* node = items; node != nullptr; node = node->next) {
        auto* item = SECRET_ITEM(node->data);
        if (!is_legacy_labeled_item(item, item_label)) {
            continue;
        }
        g_object_ref(item);
        refs.push_back(item);
    }
    g_list_free_full(items, g_object_unref);
    return refs;
}

bool delete_item_refs(std::vector<SecretItem*>& refs) {
    GError* err = nullptr;
    std::size_t index = 0;
    for (; index < refs.size(); ++index) {
        auto* item = refs[index];
        if (!secret_item_delete_sync(item, nullptr, &err)) {
            g_object_unref(item);
            ++index;
            break;
        }
        g_object_unref(item);
        err = nullptr;
    }
    for (; index < refs.size(); ++index) {
        g_object_unref(refs[index]);
    }
    refs.clear();
    if (err) {
        g_error_free(err);
        return false;
    }
    return true;
}

struct LegacyEnrollmentSnapshot {
    std::string blob;
    std::vector<SecretItem*> item_refs;
};

LegacyEnrollmentSnapshot load_legacy_enrollment_snapshot(
    const std::string& account_attribute,
    const std::string& item_label
) {
    LegacyEnrollmentSnapshot snapshot;
    snapshot.item_refs = collect_legacy_item_refs(account_attribute, item_label);
    if (snapshot.item_refs.empty()) {
        return snapshot;
    }

    std::optional<std::string> blob;
    for (auto* item : snapshot.item_refs) {
        GError* err = nullptr;
        auto secret = load_item_secret_text(item, &err);
        if (err) {
            release_item_refs(snapshot.item_refs);
            throw_keyring_io_error(err, "Failed to load legacy enrollment secret");
        }
        if (!secret.has_value() || secret->empty()) {
            release_item_refs(snapshot.item_refs);
            throw KeyringCorruptException();
        }
        if (!blob.has_value()) {
            blob = *secret;
            continue;
        }
        if (*blob != *secret) {
            release_item_refs(snapshot.item_refs);
            throw StorageException("Multiple legacy enrollment items with different contents");
        }
    }
    snapshot.blob = std::move(*blob);
    return snapshot;
}

bool legacy_refs_match_blob(
    const std::string& expected_blob,
    const std::vector<SecretItem*>& legacy_item_refs
) {
    for (auto* item : legacy_item_refs) {
        GError* err = nullptr;
        auto secret = load_item_secret_text(item, &err);
        if (err) {
            throw_keyring_io_error(err, "Failed to load legacy item");
        }
        if (!secret.has_value() || *secret != expected_blob) {
            return false;
        }
    }
    return !legacy_item_refs.empty();
}

#endif

} // namespace

// --- MemorySecretStore ---

std::optional<std::string> MemorySecretStore::read(const std::string& key) {
    auto it = data_.find(key);
    if (it != data_.end()) return it->second;
    return std::nullopt;
}

void MemorySecretStore::write(const std::string& key, const std::string& value) {
    data_[key] = value;
}

void MemorySecretStore::delete_key(const std::string& key) {
    data_.erase(key);
}

void MemorySecretStore::clear() {
    data_.clear();
}

void MemorySecretStore::replace_all(std::map<std::string, std::string> data) {
    replace(std::move(data));
}

bool MemorySecretStore::contains_key(const std::string& key) {
    return data_.find(key) != data_.end();
}

std::map<std::string, std::string> MemorySecretStore::read_all() {
    return data_;
}

// --- SecretServiceStore ---

SecretServiceStore::SecretServiceStore(std::string application_id)
    : application_id_(std::move(application_id)),
      schema_name_("default"),
      account_attribute_(application_id_ + ".secureStorage"),
      item_label_(application_id_ + "/FlutterSecureStorage") {}

bool SecretServiceStore::is_secret_service_available() {
    GError* err = nullptr;
    GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &err);
    if (!bus) {
        if (err) g_error_free(err);
        return false;
    }

    GVariant* reply = g_dbus_connection_call_sync(
        bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "NameHasOwner",
        g_variant_new("(s)", "org.freedesktop.secrets"), G_VARIANT_TYPE("(b)"),
        G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &err
    );

    g_object_unref(bus);

    if (!reply) {
        if (err) g_error_free(err);
        return false;
    }

    gboolean has_owner = FALSE;
    g_variant_get(reply, "(b)", &has_owner);
    g_variant_unref(reply);
    return has_owner == TRUE;
}

SecretServiceStore::Status SecretServiceStore::check_status() {
    if (!is_secret_service_available()) {
        return Status::MissingService;
    }

#ifdef HAVE_LIBSECRET
    GError* err = nullptr;
    SecretService* service = secret_service_get_sync(SECRET_SERVICE_OPEN_SESSION, nullptr, &err);
    if (!service) {
        if (err && g_error_matches(err, SECRET_ERROR, SECRET_ERROR_IS_LOCKED)) {
            g_error_free(err);
            return Status::Locked;
        }
        if (err) g_error_free(err);
        return Status::MissingService;
    }
    auto collection_locked = [&](const char* alias) -> bool {
        SecretCollection* collection =
            secret_collection_for_alias_sync(service, alias, SECRET_COLLECTION_NONE, nullptr, &err);
        if (err) {
            g_error_free(err);
            err = nullptr;
            return false;
        }
        if (!collection) {
            return false;
        }
        const gboolean locked = secret_collection_get_locked(collection);
        g_object_unref(collection);
        return locked == TRUE;
    };
    if (collection_locked(SECRET_COLLECTION_DEFAULT) || collection_locked("login")) {
        g_object_unref(service);
        return Status::Locked;
    }
    g_object_unref(service);
#endif
    return Status::Available;
}

void SecretServiceStore::require_writable() const {
    if (legacy_pending_) {
        throw LegacyEnrollmentPendingException();
    }
    if (read_state_ != ReadState::Ok && read_state_ != ReadState::Empty) {
        if (read_state_ == ReadState::Locked) throw KeyringLockedException();
        if (read_state_ == ReadState::Corrupt) throw KeyringCorruptException();
        if (read_state_ == ReadState::Unavailable) throw KeyringUnavailableException();
        throw StorageException("Keyring was not read successfully; refusing to write");
    }
}

#ifdef HAVE_LIBSECRET
std::optional<std::string> SecretServiceStore::lookup_native_secret() {
    GError* err = nullptr;
    gchar* secret_data = secret_password_lookup_sync(
        &kFssSchema,
        nullptr,
        &err,
        "account", account_attribute_.c_str(),
        nullptr
    );
    if (err) {
        std::string err_msg = err->message ? err->message : "Unknown error";
        const bool is_locked = g_error_matches(err, SECRET_ERROR, SECRET_ERROR_IS_LOCKED);
        g_error_free(err);
        if (is_locked) throw KeyringLockedException();
        throw StorageException("Secret Service lookup error: " + err_msg);
    }
    if (!secret_data) {
        ensure_keyring_unlocked_for_account(account_attribute_, item_label_);
        return std::nullopt;
    }
    std::string out(secret_data);
    secret_password_free(secret_data);
    return out;
}

std::optional<std::string> SecretServiceStore::find_legacy_enrollment_json() {
    auto snapshot = load_legacy_enrollment_snapshot(account_attribute_, item_label_);
    release_item_refs(snapshot.item_refs);
    if (snapshot.blob.empty()) {
        return std::nullopt;
    }
    return snapshot.blob;
}

bool SecretServiceStore::write_native_json(const std::string& json) {
    GError* err = nullptr;
    const gboolean success = secret_password_store_sync(
        &kFssSchema,
        SECRET_COLLECTION_DEFAULT,
        item_label_.c_str(),
        json.c_str(),
        nullptr,
        &err,
        "account", account_attribute_.c_str(),
        nullptr
    );
    if (!success || err) {
        std::string err_msg = err && err->message ? err->message : "Failed to store secret";
        const bool is_locked = err && g_error_matches(err, SECRET_ERROR, SECRET_ERROR_IS_LOCKED);
        if (err) g_error_free(err);
        if (is_locked) throw KeyringLockedException();
        throw StorageException("Secret Service store error: " + err_msg);
    }
    return true;
}

bool SecretServiceStore::migrate_legacy_to_native(
    const std::string& legacy_blob,
    const std::map<std::string, std::string>& data
) {
    bool legacy_corrupt = false;
    auto parsed_legacy = parse_keyring_json_object(legacy_blob, legacy_corrupt);
    if (legacy_corrupt || !parsed_legacy.has_value() || *parsed_legacy != data ||
        !looks_like_fss_enrollment(*parsed_legacy)) {
        return false;
    }
    const std::string& blob = legacy_blob;

    auto legacy_refs = collect_legacy_item_refs(account_attribute_, item_label_);
    if (legacy_refs.empty()) {
        return false;
    }
    if (!legacy_refs_match_blob(legacy_blob, legacy_refs)) {
        release_item_refs(legacy_refs);
        return false;
    }

    try {
        write_native_json(blob);
    } catch (...) {
        release_item_refs(legacy_refs);
        return false;
    }
    std::optional<std::string> verify;
    try {
        verify = lookup_native_secret();
    } catch (...) {
        release_item_refs(legacy_refs);
        return false;
    }
    if (!verify.has_value() || *verify != blob) {
        release_item_refs(legacy_refs);
        return false;
    }
    bool corrupt = false;
    auto parsed = parse_keyring_json_object(*verify, corrupt);
    if (corrupt || !parsed.has_value() || !looks_like_fss_enrollment(*parsed)) {
        release_item_refs(legacy_refs);
        return false;
    }
  if (!legacy_refs_match_blob(blob, legacy_refs)) {
        release_item_refs(legacy_refs);
        return false;
    }
    if (!delete_item_refs(legacy_refs)) {
        return false;
    }

    const auto counts = probe_keyring_enrollment_items(account_attribute_, item_label_);
    if (counts.native_items != 1 || counts.legacy_items != 0) {
        return false;
    }
    try {
        auto still_native = lookup_native_secret();
        return still_native.has_value() && *still_native == blob;
    } catch (...) {
        return false;
    }
}
#endif

void SecretServiceStore::ensure_prepared() {
    if (prepared_ || migrating_) {
        return;
    }
#ifdef HAVE_LIBSECRET
    legacy_pending_ = false;

    std::optional<std::string> native_blob;
    try {
        native_blob = lookup_native_secret();
    } catch (const KeyringLockedException&) {
        throw;
    } catch (const StorageException&) {
        throw;
    }

    LegacyEnrollmentSnapshot legacy;
    try {
        legacy = load_legacy_enrollment_snapshot(account_attribute_, item_label_);
    } catch (const KeyringLockedException&) {
        throw;
    } catch (const KeyringCorruptException&) {
        legacy_pending_ = true;
        throw;
    } catch (const StorageException&) {
        throw;
    }

    const bool has_native_item = native_blob.has_value();
    const bool has_legacy = !legacy.blob.empty();
    bool native_corrupt = false;
    const std::string native_text = has_native_item ? *native_blob : std::string{};
    const KeyringBlobKind native_kind = classify_keyring_blob(native_text, native_corrupt);

    if (native_corrupt || native_kind == KeyringBlobKind::PartialEnrollment) {
        release_item_refs(legacy.item_refs);
        legacy_pending_ = has_legacy;
        throw KeyringCorruptException();
    }

    if (native_kind == KeyringBlobKind::ValidEnrollment) {
        if (has_legacy) {
            bool legacy_corrupt = false;
            auto legacy_parsed = parse_keyring_json_object(legacy.blob, legacy_corrupt);
            const bool legacy_enrollment =
                !legacy_corrupt && legacy_parsed.has_value() && looks_like_fss_enrollment(*legacy_parsed);

            if (legacy_enrollment && legacy.blob != *native_blob) {
                release_item_refs(legacy.item_refs);
                legacy_pending_ = true;
                throw LegacyEnrollmentPendingException();
            }
            if (legacy_enrollment && legacy.blob == *native_blob) {
                if (!legacy_refs_match_blob(*native_blob, legacy.item_refs)) {
                    release_item_refs(legacy.item_refs);
                    legacy_pending_ = true;
                    throw LegacyEnrollmentPendingException();
                }
                if (!delete_item_refs(legacy.item_refs)) {
                    legacy_pending_ = true;
                    throw LegacyEnrollmentPendingException();
                }
                const auto counts = probe_keyring_enrollment_items(account_attribute_, item_label_);
                if (counts.native_items != 1 || counts.legacy_items != 0) {
                    legacy_pending_ = true;
                    throw LegacyEnrollmentPendingException();
                }
            } else {
                release_item_refs(legacy.item_refs);
            }
        }

        prepared_ = true;
        return;
    }

    if (native_kind == KeyringBlobKind::EmptyCleared ||
        native_kind == KeyringBlobKind::PreferenceOnly ||
        native_kind == KeyringBlobKind::Missing) {
        if (!has_legacy) {
            release_item_refs(legacy.item_refs);
            prepared_ = true;
            return;
        }
    } else if (!has_legacy) {
        prepared_ = true;
        return;
    }

    bool legacy_corrupt = false;
    auto legacy_parsed = parse_keyring_json_object(legacy.blob, legacy_corrupt);
    if (legacy_corrupt || !legacy_parsed.has_value()) {
        release_item_refs(legacy.item_refs);
        legacy_pending_ = true;
        throw KeyringCorruptException();
    }
    if (!looks_like_fss_enrollment(*legacy_parsed)) {
        release_item_refs(legacy.item_refs);
        prepared_ = true;
        return;
    }

    const std::string legacy_blob_copy = legacy.blob;
    release_item_refs(legacy.item_refs);

    MigratingScope migrating(*this);
    const bool migrated = migrate_legacy_to_native(legacy_blob_copy, *legacy_parsed);
    if (!migrated) {
        legacy_pending_ = true;
        throw LegacyEnrollmentPendingException();
    }
#endif
    prepared_ = true;
}

std::map<std::string, std::string> SecretServiceStore::fetch_from_keyring() {
    if (!is_secret_service_available()) {
        read_state_ = ReadState::Unavailable;
        throw KeyringUnavailableException();
    }

#ifdef HAVE_LIBSECRET
    try {
        ensure_prepared();
    } catch (const KeyringLockedException&) {
        read_state_ = ReadState::Locked;
        throw;
    } catch (const KeyringCorruptException&) {
        read_state_ = ReadState::Corrupt;
        throw;
    } catch (const LegacyEnrollmentPendingException&) {
        read_state_ = ReadState::Corrupt;
        throw;
    } catch (const StorageException&) {
        read_state_ = ReadState::Corrupt;
        throw;
    }

    std::optional<std::string> secret_data;
    try {
        secret_data = lookup_native_secret();
    } catch (const KeyringLockedException&) {
        read_state_ = ReadState::Locked;
        throw;
    }

    std::map<std::string, std::string> result;
    if (!secret_data.has_value() || secret_data->empty()) {
        ensure_keyring_unlocked_for_account(account_attribute_, item_label_);
        read_state_ = ReadState::Empty;
        return result;
    }

    bool corrupt = false;
    const auto kind = classify_keyring_blob(*secret_data, corrupt);
    if (corrupt || kind == KeyringBlobKind::PartialEnrollment) {
        read_state_ = ReadState::Corrupt;
        throw KeyringCorruptException();
    }
    auto parsed = parse_keyring_json_object(*secret_data, corrupt);
    if (!parsed.has_value()) {
        read_state_ = ReadState::Corrupt;
        throw KeyringCorruptException();
    }
    if (kind == KeyringBlobKind::EmptyCleared) {
        read_state_ = ReadState::Empty;
        return {};
    }
    read_state_ = ReadState::Ok;
    return *parsed;
#else
    read_state_ = ReadState::Unavailable;
    throw KeyringUnavailableException();
#endif
}

void SecretServiceStore::store_to_keyring(const std::map<std::string, std::string>& data) {
    if (!is_secret_service_available()) {
        read_state_ = ReadState::Unavailable;
        throw KeyringUnavailableException();
    }

#ifdef HAVE_LIBSECRET
    if (!migrating_) {
        ensure_prepared();
    }
    nlohmann::json j = nlohmann::json::object();
    for (const auto& [k, v] : data) {
        j[k] = v;
    }
    write_native_json(j.dump());
    read_state_ = ReadState::Ok;
#else
    throw KeyringUnavailableException();
#endif
}

std::optional<std::string> SecretServiceStore::read(const std::string& key) {
    auto data = fetch_from_keyring();
    auto it = data.find(key);
    if (it != data.end()) return it->second;
    return std::nullopt;
}

void SecretServiceStore::write(const std::string& key, const std::string& value) {
    require_writable();
    auto data = fetch_from_keyring();
    data[key] = value;
    store_to_keyring(data);
}

void SecretServiceStore::delete_key(const std::string& key) {
    require_writable();
    auto data = fetch_from_keyring();
    if (data.erase(key) > 0) {
        store_to_keyring(data);
    }
}

void SecretServiceStore::clear() {
    if (!is_secret_service_available()) {
        read_state_ = ReadState::Unavailable;
        throw KeyringUnavailableException();
    }

#ifdef HAVE_LIBSECRET
    if (legacy_pending_) {
        throw LegacyEnrollmentPendingException();
    }
    if (read_state_ == ReadState::Corrupt) {
        write_native_json(nlohmann::json::object().dump());
        read_state_ = ReadState::Empty;
        prepared_ = true;
        return;
    }
    require_writable();
    store_to_keyring({});
    read_state_ = ReadState::Empty;
#else
    throw KeyringUnavailableException();
#endif
}

void SecretServiceStore::replace_all(std::map<std::string, std::string> data) {
    require_writable();
    store_to_keyring(data);
    read_state_ = data.empty() ? ReadState::Empty : ReadState::Ok;
}

bool SecretServiceStore::contains_key(const std::string& key) {
    auto data = fetch_from_keyring();
    return data.find(key) != data.end();
}

std::map<std::string, std::string> SecretServiceStore::read_all() {
    return fetch_from_keyring();
}

std::shared_ptr<SecretStore> create_default_secret_store() {
    return std::make_shared<SecretServiceStore>("xyz.vidur.pux");
}

} // namespace storage
} // namespace pux
