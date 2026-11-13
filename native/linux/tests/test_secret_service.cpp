#include "test_harness.hpp"
#include "../src/storage/secret_store.hpp"
#include "../src/storage/secret_store_keyring_probe.hpp"
#include "../src/storage/fss_keyring_compat.hpp"
#include "../src/storage/record_store.hpp"
#include "../src/storage/storage_coordinator.hpp"
#include "../src/vendor/json.hpp"

const char* kFlutterUpgradeSecretJson =
    "{\"record_id\":\"87654321-4321-4321-4321-210987654321\","
    "\"public_key\":\"oVaRfoaaBI7h10MCUauxYiPWaLQaAjN_oklwaOO682M\","
    "\"private_key\":\"3h7LhAw9e7EtYS5TeRJsQqYI8v4LtpH49buqnScv9qU\","
    "\"inbox\":\"relay@pux.vidur.xyz\","
    "\"server_url\":\"https://pux.vidur.xyz\","
    "\"desktop_device_id\":\"0123456789abcdef0123456789abcdef\","
    "\"notification_permission_asked\":\"true\"}";

TEST(fss_enrollment_filter_accepts_upgrade_fixture) {
    auto j = nlohmann::json::parse(kFlutterUpgradeSecretJson);
    std::map<std::string, std::string> data;
    for (auto& item : j.items()) {
        if (item.value().is_string()) data[item.key()] = item.value().get<std::string>();
    }
    ASSERT_TRUE(pux::storage::looks_like_fss_enrollment(data));
}

TEST(fss_enrollment_filter_rejects_unrelated_items) {
    std::map<std::string, std::string> data{{"account", "not-enrollment"}};
    ASSERT_FALSE(pux::storage::looks_like_fss_enrollment(data));
}

TEST(keyring_blob_classifies_cleared_and_preference_only) {
    bool corrupt = false;
    ASSERT_TRUE(pux::storage::classify_keyring_blob("{}", corrupt) == pux::storage::KeyringBlobKind::EmptyCleared);
    ASSERT_FALSE(corrupt);
    ASSERT_TRUE(pux::storage::classify_keyring_blob("{\"notification_permission_asked\":\"true\"}", corrupt) ==
                pux::storage::KeyringBlobKind::PreferenceOnly);
    ASSERT_TRUE(pux::storage::classify_keyring_blob("{not-json", corrupt) ==
                pux::storage::KeyringBlobKind::PartialEnrollment);
    ASSERT_TRUE(corrupt);
}

TEST(fss_json_parser_detects_corruption) {
    bool corrupt = false;
    auto parsed = pux::storage::parse_keyring_json_object("{not-json", corrupt);
    ASSERT_TRUE(corrupt);
    ASSERT_FALSE(parsed.has_value());
}

TEST(secret_store_attributes_match_flutter_plugin_specification) {
    pux::storage::SecretServiceStore store("xyz.vidur.pux");
    ASSERT_EQ(store.schema_name(), "default");
    ASSERT_EQ(store.account_attribute(), "xyz.vidur.pux.secureStorage");
    ASSERT_EQ(store.item_label(), "xyz.vidur.pux/FlutterSecureStorage");
}

TEST(secret_store_fails_safely_when_keyring_unavailable) {
    pux::storage::SecretServiceStore store("xyz.vidur.pux");
    if (!pux::storage::SecretServiceStore::is_secret_service_available()) {
        ASSERT_THROWS(store.read("record_id"), pux::storage::KeyringUnavailableException);
        ASSERT_THROWS(store.write("record_id", "val"), pux::storage::KeyringUnavailableException);
    }
}

TEST(secret_store_memory_upgrade_fixture_enrollment) {
    auto mem = std::make_shared<pux::storage::MemorySecretStore>();
    auto j = nlohmann::json::parse(kFlutterUpgradeSecretJson);
    for (auto& item : j.items()) {
        if (item.value().is_string()) {
            mem->write(item.key(), item.value().get<std::string>());
        }
    }
    pux::storage::RecordStore rs(mem);
    rs.init();
    ASSERT_TRUE(rs.is_enrolled());
    ASSERT_EQ(rs.record_id().value_or(""), "87654321-4321-4321-4321-210987654321");
}

TEST(secret_store_refuses_write_after_corrupt_read_state) {
    class CorruptOnceStore : public pux::storage::SecretStore {
    public:
        int reads = 0;
        std::optional<std::string> read(const std::string&) override {
            ++reads;
            throw pux::storage::KeyringCorruptException();
        }
        void write(const std::string&, const std::string&) override {}
        void delete_key(const std::string&) override {}
        void clear() override {}
        void replace_all(std::map<std::string, std::string>) override {}
        bool contains_key(const std::string&) override { return false; }
        std::map<std::string, std::string> read_all() override { throw pux::storage::KeyringCorruptException(); }
    };
    auto store = std::make_shared<CorruptOnceStore>();
    pux::storage::RecordStore rs(store);
    ASSERT_THROWS(rs.init(), pux::storage::KeyringCorruptException);
}

#if defined(__linux__) && defined(HAVE_LIBSECRET)
#include <libsecret/secret.h>
#include <glib.h>
#include <gio/gio.h>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <string>
#include <thread>
#include <unistd.h>

namespace {

void require_available_keyring() {
    if (!pux::storage::SecretServiceStore::is_secret_service_available()) {
        SKIP_TEST("Secret Service dbus provider not running");
    }
    const auto status = pux::storage::SecretServiceStore::check_status();
    if (status == pux::storage::SecretServiceStore::Status::Locked) {
        SKIP_TEST("Secret Service keyring is locked");
    }
    if (status != pux::storage::SecretServiceStore::Status::Available) {
        SKIP_TEST("Secret Service not available for integration test");
    }
}

void require_libsecret_store(
    const char* context,
    gboolean stored,
    GError* err
) {
    if (stored && err == nullptr) {
        return;
    }
    std::string message = context;
    if (err && err->message) {
        message += ": ";
        message += err->message;
        g_error_free(err);
    } else if (err) {
        g_error_free(err);
    }
    if (std::getenv("PUX_REQUIRE_KEYRING")) {
        throw std::runtime_error(message);
    }
    SKIP_TEST(message);
}

void require_keyring_account_cleared(const std::string& account, const std::string& label) {
    if (pux::storage::clear_keyring_account_items(account, label)) {
        return;
    }
    const char* message = "failed to clear keyring test account";
    if (std::getenv("PUX_REQUIRE_KEYRING")) {
        throw std::runtime_error(message);
    }
    SKIP_TEST(message);
}

static const SecretSchema kNativeSchema = {
    "default",
    SECRET_SCHEMA_NONE,
    {{"account", SECRET_SCHEMA_ATTRIBUTE_STRING}, {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING}}
};

void seed_native_keyring_blob(
    const std::string& account,
    const std::string& label,
    const std::string& json_blob
) {
    GError* err = nullptr;
    const gboolean stored = secret_password_store_sync(
        &kNativeSchema,
        SECRET_COLLECTION_DEFAULT,
        label.c_str(),
        json_blob.c_str(),
        nullptr,
        &err,
        "account",
        account.c_str(),
        nullptr);
    require_libsecret_store("failed to seed native keyring blob", stored, err);
}

} // namespace

TEST(secret_store_legacy_migration_from_corrupted_schema_name) {
    require_available_keyring();

    constexpr const char* kTestApp = "xyz.vidur.pux.libsectest";
    const std::string account = std::string(kTestApp) + ".secureStorage";
    const std::string label = std::string(kTestApp) + "/FlutterSecureStorage";

    static const SecretSchema kBrokenNameSchema = {
        "\x22",
        SECRET_SCHEMA_NONE,
        {{"account", SECRET_SCHEMA_ATTRIBUTE_STRING}, {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING}}
    };

    require_keyring_account_cleared(account, label);

    GError* err = nullptr;
  const gboolean stored = secret_password_store_sync(
        &kBrokenNameSchema, SECRET_COLLECTION_DEFAULT, label.c_str(), kFlutterUpgradeSecretJson,
        nullptr, &err, "account", account.c_str(), nullptr);
    require_libsecret_store("failed to seed legacy keyring item", stored, err);

    auto before = pux::storage::probe_keyring_enrollment_items(account, label);
    ASSERT_EQ(before.native_items, 0);
    ASSERT_EQ(before.legacy_items, 1);

    pux::storage::SecretServiceStore store(kTestApp);
    auto all = store.read_all();
    ASSERT_TRUE(pux::storage::looks_like_fss_enrollment(all));
    ASSERT_EQ(all.at("record_id"), "87654321-4321-4321-4321-210987654321");

    auto after = pux::storage::probe_keyring_enrollment_items(account, label);
    ASSERT_EQ(after.native_items, 1);
    ASSERT_EQ(after.legacy_items, 0);

    require_keyring_account_cleared(account, label);
}

TEST(secret_store_clear_persists_empty_object_readable_after_reopen) {
    require_available_keyring();

    constexpr const char* kTestApp = "xyz.vidur.pux.libsectest.clear";
    const std::string account = std::string(kTestApp) + ".secureStorage";
    const std::string label = std::string(kTestApp) + "/FlutterSecureStorage";

    require_keyring_account_cleared(account, label);
    seed_native_keyring_blob(account, label, kFlutterUpgradeSecretJson);

    pux::storage::SecretServiceStore store(kTestApp);
    auto enrolled = store.read_all();
    ASSERT_TRUE(pux::storage::looks_like_fss_enrollment(enrolled));

    store.clear();
    ASSERT_TRUE(store.last_read_state() == pux::storage::SecretServiceStore::ReadState::Empty);

    pux::storage::SecretServiceStore reopened(kTestApp);
    auto after_clear = reopened.read_all();
    ASSERT_TRUE(after_clear.empty());
    ASSERT_TRUE(reopened.last_read_state() == pux::storage::SecretServiceStore::ReadState::Empty);

    auto counts = pux::storage::probe_keyring_enrollment_items(account, label);
    ASSERT_EQ(counts.native_items, 1);
    ASSERT_EQ(counts.legacy_items, 0);

    require_keyring_account_cleared(account, label);
}

TEST(secret_store_preference_only_native_migrates_legacy_enrollment) {
    require_available_keyring();

    constexpr const char* kTestApp = "xyz.vidur.pux.libsectest.prefs";
    const std::string account = std::string(kTestApp) + ".secureStorage";
    const std::string label = std::string(kTestApp) + "/FlutterSecureStorage";

    static const SecretSchema kBrokenNameSchema = {
        "\x22",
        SECRET_SCHEMA_NONE,
        {{"account", SECRET_SCHEMA_ATTRIBUTE_STRING}, {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING}}
    };

    require_keyring_account_cleared(account, label);
    seed_native_keyring_blob(account, label, "{\"notification_permission_asked\":\"true\"}");

    GError* err = nullptr;
    const gboolean stored_legacy = secret_password_store_sync(
        &kBrokenNameSchema,
        SECRET_COLLECTION_DEFAULT,
        label.c_str(),
        kFlutterUpgradeSecretJson,
        nullptr,
        &err,
        "account",
        account.c_str(),
        nullptr);
    require_libsecret_store("failed to seed legacy enrollment alongside preferences", stored_legacy, err);

    auto before = pux::storage::probe_keyring_enrollment_items(account, label);
    ASSERT_EQ(before.native_items, 1);
    ASSERT_EQ(before.legacy_items, 1);

    pux::storage::SecretServiceStore store(kTestApp);
    auto migrated = store.read_all();
    ASSERT_TRUE(pux::storage::looks_like_fss_enrollment(migrated));
    ASSERT_EQ(migrated.at("record_id"), "87654321-4321-4321-4321-210987654321");

    auto after = pux::storage::probe_keyring_enrollment_items(account, label);
    ASSERT_EQ(after.native_items, 1);
    ASSERT_EQ(after.legacy_items, 0);

    require_keyring_account_cleared(account, label);
}

TEST(secret_store_preserves_legacy_on_native_corrupt_conflict) {
    require_available_keyring();

    constexpr const char* kTestApp = "xyz.vidur.pux.libsectest.corrupt";
    const std::string account = std::string(kTestApp) + ".secureStorage";
    const std::string label = std::string(kTestApp) + "/FlutterSecureStorage";

    static const SecretSchema kBrokenNameSchema = {
        "\x22",
        SECRET_SCHEMA_NONE,
        {{"account", SECRET_SCHEMA_ATTRIBUTE_STRING}, {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING}}
    };
    require_keyring_account_cleared(account, label);

    GError* err = nullptr;
    gboolean stored_native = secret_password_store_sync(
        &kNativeSchema, SECRET_COLLECTION_DEFAULT, label.c_str(), "{not-valid-json",
        nullptr, &err, "account", account.c_str(), nullptr);
    require_libsecret_store("failed to seed corrupt native item", stored_native, err);
    err = nullptr;
    gboolean stored_legacy = secret_password_store_sync(
        &kBrokenNameSchema, SECRET_COLLECTION_DEFAULT, label.c_str(), kFlutterUpgradeSecretJson,
        nullptr, &err, "account", account.c_str(), nullptr);
    require_libsecret_store("failed to seed legacy item", stored_legacy, err);

    auto before = pux::storage::probe_keyring_enrollment_items(account, label);
    ASSERT_EQ(before.native_items, 1);
    ASSERT_EQ(before.legacy_items, 1);

    pux::storage::SecretServiceStore store(kTestApp);
    ASSERT_THROWS(store.read_all(), pux::storage::KeyringCorruptException);

    auto after = pux::storage::probe_keyring_enrollment_items(account, label);
    ASSERT_EQ(after.native_items, 1);
    ASSERT_EQ(after.legacy_items, 1);

    require_keyring_account_cleared(account, label);
}

TEST(secret_store_preserves_both_on_enrollment_conflict) {
    require_available_keyring();

    constexpr const char* kTestApp = "xyz.vidur.pux.libsectest.conflict";
    const std::string account = std::string(kTestApp) + ".secureStorage";
    const std::string label = std::string(kTestApp) + "/FlutterSecureStorage";

    static const SecretSchema kBrokenNameSchema = {
        "\x22",
        SECRET_SCHEMA_NONE,
        {{"account", SECRET_SCHEMA_ATTRIBUTE_STRING}, {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING}}
    };
    const std::string native_json =
        "{\"record_id\":\"11111111-1111-1111-1111-111111111111\","
        "\"public_key\":\"oVaRfoaaBI7h10MCUauxYiPWaLQaAjN_oklwaOO682M\","
        "\"private_key\":\"3h7LhAw9e7EtYS5TeRJsQqYI8v4LtpH49buqnScv9qU\","
        "\"inbox\":\"a@pux.vidur.xyz\","
        "\"server_url\":\"https://pux.vidur.xyz\","
        "\"desktop_device_id\":\"0123456789abcdef0123456789abcdef\","
        "\"notification_permission_asked\":\"true\"}";

    require_keyring_account_cleared(account, label);

    GError* err = nullptr;
    gboolean stored_native = secret_password_store_sync(
        &kNativeSchema, SECRET_COLLECTION_DEFAULT, label.c_str(), native_json.c_str(),
        nullptr, &err, "account", account.c_str(), nullptr);
    require_libsecret_store("failed to seed native enrollment item", stored_native, err);
    err = nullptr;
    gboolean stored_legacy = secret_password_store_sync(
        &kBrokenNameSchema, SECRET_COLLECTION_DEFAULT, label.c_str(), kFlutterUpgradeSecretJson,
        nullptr, &err, "account", account.c_str(), nullptr);
    require_libsecret_store("failed to seed legacy enrollment item", stored_legacy, err);

    pux::storage::SecretServiceStore store(kTestApp);
    ASSERT_THROWS(store.read_all(), pux::storage::LegacyEnrollmentPendingException);
    ASSERT_TRUE(store.legacy_enrollment_pending());

    auto counts = pux::storage::probe_keyring_enrollment_items(account, label);
    ASSERT_EQ(counts.native_items, 1);
    ASSERT_EQ(counts.legacy_items, 1);

    require_keyring_account_cleared(account, label);
}

TEST(secret_store_retry_after_pending_migration_with_legacy_only) {
    require_available_keyring();

    constexpr const char* kTestApp = "xyz.vidur.pux.libsectest.retry";
    const std::string account = std::string(kTestApp) + ".secureStorage";
    const std::string label = std::string(kTestApp) + "/FlutterSecureStorage";

    static const SecretSchema kBrokenNameSchema = {
        "\x22",
        SECRET_SCHEMA_NONE,
        {{"account", SECRET_SCHEMA_ATTRIBUTE_STRING}, {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING}}
    };

    require_keyring_account_cleared(account, label);

    GError* err = nullptr;
    gboolean stored = secret_password_store_sync(
        &kBrokenNameSchema, SECRET_COLLECTION_DEFAULT, label.c_str(), kFlutterUpgradeSecretJson,
        nullptr, &err, "account", account.c_str(), nullptr);
    require_libsecret_store("failed to seed legacy migration fixture", stored, err);

    pux::storage::SecretServiceStore first(kTestApp);
    auto first_read = first.read_all();
    ASSERT_EQ(first_read.at("record_id"), "87654321-4321-4321-4321-210987654321");

    pux::storage::SecretServiceStore retry(kTestApp);
    auto second_read = retry.read_all();
    ASSERT_EQ(second_read.at("record_id"), "87654321-4321-4321-4321-210987654321");

    auto counts = pux::storage::probe_keyring_enrollment_items(account, label);
    ASSERT_EQ(counts.native_items, 1);
    ASSERT_EQ(counts.legacy_items, 0);

    require_keyring_account_cleared(account, label);
}

nlohmann::json make_libsecret_enrollment_payload() {
    return nlohmann::json::parse(
        "{\"v\":1,"
        "\"record_id\":\"22222222-2222-2222-2222-222222222221\","
        "\"public_key\":\"oVaRfoaaBI7h10MCUauxYiPWaLQaAjN_oklwaOO682M\","
        "\"private_key\":\"3h7LhAw9e7EtYS5TeRJsQqYI8v4LtpH49buqnScv9qU\","
        "\"inbox\":\"import-test@pux.vidur.xyz\","
        "\"server\":\"https://pux.vidur.xyz\"}");
}

std::string sibling_locked_probe_path() {
    char path[4096];
    const ssize_t length = readlink("/proc/self/exe", path, sizeof(path) - 1);
    if (length <= 0) {
        return {};
    }
    path[length] = '\0';
    const std::string executable(path);
    const auto slash = executable.rfind('/');
    if (slash == std::string::npos) {
        return {};
    }
    return executable.substr(0, slash + 1) + "pux_linux_keyring_locked_probe";
}

int spawn_locked_probe(const char* test_app) {
    const std::string probe = sibling_locked_probe_path();
    if (probe.empty()) {
        return -1;
    }
    gchar* argv[] = {
        const_cast<gchar*>(probe.c_str()),
        const_cast<gchar*>(test_app),
        nullptr,
    };
    GError* err = nullptr;
    gint exit_status = 0;
    const gboolean ok = g_spawn_sync(
        nullptr,
        argv,
        nullptr,
        G_SPAWN_SEARCH_PATH,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        &exit_status,
        &err);
    if (!ok) {
        if (err) {
            g_error_free(err);
        }
        return -1;
    }
    return exit_status;
}

TEST(record_store_save_enrollment_roundtrip_on_libsecret) {
    require_available_keyring();

    constexpr const char* kTestApp = "xyz.vidur.pux.libsectest.import";
    const std::string account = std::string(kTestApp) + ".secureStorage";
    const std::string label = std::string(kTestApp) + "/FlutterSecureStorage";

    require_keyring_account_cleared(account, label);
    seed_native_keyring_blob(account, label, "{\"notification_permission_asked\":\"true\"}");

    auto payload = make_libsecret_enrollment_payload();
    {
        auto store = std::make_shared<pux::storage::SecretServiceStore>(kTestApp);
        pux::storage::RecordStore rs(store);
        rs.init();
        rs.save_enrollment(payload);
        ASSERT_TRUE(rs.is_enrolled());
        ASSERT_EQ(rs.record_id().value_or(""), payload["record_id"].get<std::string>());
    }

    auto reopened_store = std::make_shared<pux::storage::SecretServiceStore>(kTestApp);
    pux::storage::RecordStore rs2(reopened_store);
    rs2.init();
    ASSERT_TRUE(rs2.is_enrolled());
    ASSERT_EQ(rs2.inbox().value_or(""), payload["inbox"].get<std::string>());
    ASSERT_EQ(rs2.notification_permission_asked(), true);

    require_keyring_account_cleared(account, label);
}

TEST(record_store_save_enrollment_never_persists_partial_native_blob) {
    require_available_keyring();

    constexpr const char* kTestApp = "xyz.vidur.pux.libsectest.partial";
    const std::string account = std::string(kTestApp) + ".secureStorage";
    const std::string label = std::string(kTestApp) + "/FlutterSecureStorage";
    const std::string partial_json =
        "{\"inbox\":\"partial@pux.vidur.xyz\","
        "\"public_key\":\"oVaRfoaaBI7h10MCUauxYiPWaLQaAjN_oklwaOO682M\","
        "\"server_url\":\"https://pux.vidur.xyz\"}";

    require_keyring_account_cleared(account, label);
    seed_native_keyring_blob(account, label, partial_json);

    pux::storage::SecretServiceStore corrupt_store(kTestApp);
    ASSERT_THROWS(corrupt_store.read_all(), pux::storage::KeyringCorruptException);
    corrupt_store.clear();
    ASSERT_TRUE(corrupt_store.last_read_state() == pux::storage::SecretServiceStore::ReadState::Empty);

    auto payload = make_libsecret_enrollment_payload();
    auto store = std::make_shared<pux::storage::SecretServiceStore>(kTestApp);
    pux::storage::RecordStore rs(store);
    rs.init();
    rs.save_enrollment(payload);
    ASSERT_TRUE(rs.is_enrolled());

    require_keyring_account_cleared(account, label);
}

TEST(storage_coordinator_reset_corrupt_native_matches_main_wiring) {
    require_available_keyring();

    constexpr const char* kTestApp = "xyz.vidur.pux.libsectest.coordreset";
    const std::string account = std::string(kTestApp) + ".secureStorage";
    const std::string label = std::string(kTestApp) + "/FlutterSecureStorage";
    const std::string partial_json =
        "{\"inbox\":\"partial@pux.vidur.xyz\","
        "\"public_key\":\"oVaRfoaaBI7h10MCUauxYiPWaLQaAjN_oklwaOO682M\","
        "\"server_url\":\"https://pux.vidur.xyz\"}";

    require_keyring_account_cleared(account, label);
    seed_native_keyring_blob(account, label, partial_json);

    auto backend = std::make_shared<pux::storage::SecretServiceStore>(kTestApp);
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::StorageCoordinator coordinator(backend, snapshot);
    auto record = std::make_shared<pux::storage::RecordStore>(snapshot);

    bool init_finished = false;
    std::string init_error;
    coordinator.submit_durable(
        [](pux::storage::RecordStore& store) { store.init(); },
        [&](const std::string& error) {
            init_error = error;
            init_finished = true;
        });
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!init_finished && std::chrono::steady_clock::now() < deadline) {
        while (g_main_context_pending(nullptr)) {
            g_main_context_iteration(nullptr, FALSE);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    ASSERT_TRUE(init_finished);
    ASSERT_FALSE(init_error.empty());
    ASSERT_TRUE(coordinator.corrupt_native_reset_allowed());
    ASSERT_FALSE(record->is_enrolled());

    bool reset_finished = false;
    std::string reset_error;
    coordinator.submit_reset_corrupt_native([&](const std::string& error) {
        reset_error = error;
        reset_finished = true;
    });
    deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!reset_finished && std::chrono::steady_clock::now() < deadline) {
        while (g_main_context_pending(nullptr)) {
            g_main_context_iteration(nullptr, FALSE);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    ASSERT_TRUE(reset_finished);
    ASSERT_TRUE(reset_error.empty());
    ASSERT_FALSE(coordinator.corrupt_native_reset_allowed());

    record->init();
    ASSERT_FALSE(record->is_enrolled());

    auto payload = make_libsecret_enrollment_payload();
    coordinator.submit_durable(
        [&](pux::storage::RecordStore& store) { store.save_enrollment(payload); },
        [&](const std::string& error) { reset_error = error; reset_finished = true; });
    reset_finished = false;
    deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!reset_finished && std::chrono::steady_clock::now() < deadline) {
        while (g_main_context_pending(nullptr)) {
            g_main_context_iteration(nullptr, FALSE);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    ASSERT_TRUE(reset_finished);
    ASSERT_TRUE(reset_error.empty());
    record->init();
    ASSERT_TRUE(record->is_enrolled());

    require_keyring_account_cleared(account, label);
}

TEST(secret_store_locked_collection_reports_locked_not_empty) {
    require_available_keyring();

    if (!g_find_program_in_path("gnome-keyring-daemon") || !g_find_program_in_path("dbus-launch")) {
        SKIP_TEST("gnome-keyring-daemon or dbus-launch not available for isolated locked test");
    }

    constexpr const char* kTestApp = "xyz.vidur.pux.libsectest.locked";

    const int child_code = spawn_locked_probe(kTestApp);
    if (child_code < 0) {
        if (std::getenv("PUX_REQUIRE_KEYRING")) {
            throw std::runtime_error("failed to spawn isolated locked keyring probe");
        }
        SKIP_TEST("failed to spawn isolated locked keyring probe");
    }
    if (child_code != 0) {
        if (std::getenv("PUX_REQUIRE_KEYRING")) {
            throw std::runtime_error(
                "isolated locked keyring test failed with code " + std::to_string(child_code));
        }
        SKIP_TEST("isolated locked keyring test failed");
    }

    ASSERT_TRUE(
        pux::storage::SecretServiceStore::check_status() == pux::storage::SecretServiceStore::Status::Available);
}
#endif
