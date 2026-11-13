#include "secret_store_keyring_probe.hpp"

#if defined(__linux__) && defined(HAVE_LIBSECRET)

#include <libsecret/secret.h>
#include <cstring>

namespace pux::storage {

namespace {

constexpr const char* kNativeSchemaName = "default";

static const SecretSchema kFssSchema = {
    kNativeSchemaName,
    SECRET_SCHEMA_NONE,
    {
        {"account", SECRET_SCHEMA_ATTRIBUTE_STRING},
        {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING}
    }
};

bool schema_is_native(const char* schema) {
    return schema && strcmp(schema, kNativeSchemaName) == 0;
}

bool label_matches(const char* label, const std::string& expected) {
    return label && strcmp(label, expected.c_str()) == 0;
}

GList* search_account_items(const std::string& account_attribute, GError** err) {
    SecretService* service = secret_service_get_sync(SECRET_SERVICE_OPEN_SESSION, nullptr, err);
    if (!service) return nullptr;
    GHashTable* attrs = secret_attributes_build(&kFssSchema, "account", account_attribute.c_str(), nullptr);
    GList* items = secret_service_search_sync(service, nullptr, attrs, SECRET_SEARCH_ALL, nullptr, err);
    g_hash_table_unref(attrs);
    g_object_unref(service);
    return items;
}

} // namespace

KeyringEnrollmentItemCounts probe_keyring_enrollment_items(
    const std::string& account_attribute,
    const std::string& item_label
) {
    KeyringEnrollmentItemCounts counts;
    GError* err = nullptr;
    GList* items = search_account_items(account_attribute, &err);
    if (err) {
        g_error_free(err);
        return counts;
    }
    if (!items) return counts;

    for (GList* node = items; node != nullptr; node = node->next) {
        auto* item = SECRET_ITEM(node->data);
        if (!label_matches(secret_item_get_label(item), item_label)) continue;
        if (schema_is_native(secret_item_get_schema_name(item))) {
            ++counts.native_items;
        } else {
            ++counts.legacy_items;
        }
    }
    g_list_free_full(items, g_object_unref);
    return counts;
}

bool clear_keyring_account_items(const std::string& account_attribute, const std::string& item_label) {
    GError* err = nullptr;
    GList* items = search_account_items(account_attribute, &err);
    if (err) {
        g_error_free(err);
        return false;
    }
    if (!items) return true;

    bool ok = true;
    for (GList* node = items; node != nullptr; node = node->next) {
        auto* item = SECRET_ITEM(node->data);
        if (!label_matches(secret_item_get_label(item), item_label)) continue;
        if (!secret_item_delete_sync(item, nullptr, &err)) {
            if (err) g_error_free(err);
            ok = false;
            break;
        }
        err = nullptr;
    }
    g_list_free_full(items, g_object_unref);
    return ok;
}

} // namespace pux::storage

#endif
