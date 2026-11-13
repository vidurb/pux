// Spawned by secret_store_locked_collection_reports_locked_not_empty (not run from threaded tests).
#if defined(__linux__) && defined(HAVE_LIBSECRET)

#include "../src/storage/secret_store.hpp"
#include <libsecret/secret.h>
#include <glib.h>
#include <chrono>
#include <cstdlib>
#include <string>
#include <thread>
#include <unistd.h>

namespace {

const char* test_keyring_password() {
    if (const char* env = std::getenv("PUX_TEST_KEYRING_PASSWORD")) {
        return env;
    }
    return "testpw";
}

bool parse_dbus_launch_var(const std::string& sh_output, const char* key, std::string* value) {
    const std::string needle = std::string(key) + "='";
    const auto start = sh_output.find(needle);
    if (start == std::string::npos) {
        return false;
    }
    const auto value_start = start + needle.size();
    const auto value_end = sh_output.find('\'', value_start);
    if (value_end == std::string::npos) {
        return false;
    }
    *value = sh_output.substr(value_start, value_end - value_start);
    return true;
}

bool bootstrap_isolated_keyring_session(const std::string& child_home) {
    g_mkdir_with_parents(child_home.c_str(), 0700);
    if (setenv("HOME", child_home.c_str(), 1) != 0) {
        return false;
    }
    if (const char* display = std::getenv("DISPLAY")) {
        setenv("DISPLAY", display, 1);
    }

    gchar* stdout_buf = nullptr;
    gint exit_status = 0;
    if (!g_spawn_command_line_sync("dbus-launch --sh-syntax", &stdout_buf, nullptr, &exit_status, nullptr)
        || exit_status != 0 || stdout_buf == nullptr) {
        if (stdout_buf) {
            g_free(stdout_buf);
        }
        return false;
    }

    std::string dbus_output(stdout_buf);
    g_free(stdout_buf);
    std::string dbus_address;
    if (!parse_dbus_launch_var(dbus_output, "DBUS_SESSION_BUS_ADDRESS", &dbus_address)) {
        return false;
    }
    if (setenv("DBUS_SESSION_BUS_ADDRESS", dbus_address.c_str(), 1) != 0) {
        return false;
    }

    gchar* unlock_command = g_strdup_printf(
        "sh -c \"eval $(echo -n '%s' | gnome-keyring-daemon --unlock --components=secrets)\"",
        test_keyring_password());
    const gboolean unlock_ok =
        g_spawn_command_line_sync(unlock_command, nullptr, nullptr, &exit_status, nullptr);
    g_free(unlock_command);
    if (!unlock_ok || exit_status != 0) {
        return false;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    return pux::storage::SecretServiceStore::is_secret_service_available();
}

int run_locked_collection_probe(const char* test_app) {
    const std::string child_home = std::string("/tmp/pux-locked-") + std::to_string(getpid());
    if (!bootstrap_isolated_keyring_session(child_home)) {
        return 10;
    }

    GError* err = nullptr;
    SecretService* service = secret_service_get_sync(SECRET_SERVICE_OPEN_SESSION, nullptr, &err);
    if (!service) {
        if (err) {
            g_error_free(err);
        }
        return 11;
    }
    SecretCollection* login =
        secret_collection_for_alias_sync(service, "login", SECRET_COLLECTION_NONE, nullptr, &err);
    if (!login) {
        if (err) {
            g_error_free(err);
        }
        g_object_unref(service);
        return 12;
    }
    GList* lock_list = g_list_append(nullptr, login);
    const gboolean locked = secret_service_lock_sync(service, lock_list, nullptr, nullptr, &err);
    g_list_free(lock_list);
    g_object_unref(service);
    if (err) {
        g_error_free(err);
    }
    if (locked != TRUE) {
        return 13;
    }

    if (pux::storage::SecretServiceStore::check_status()
        != pux::storage::SecretServiceStore::Status::Locked) {
        return 14;
    }

    pux::storage::SecretServiceStore store(test_app);
    try {
        store.read_all();
        return 15;
    } catch (const pux::storage::KeyringLockedException&) {
        if (store.last_read_state() != pux::storage::SecretServiceStore::ReadState::Locked) {
            return 16;
        }
    } catch (...) {
        return 17;
    }
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        return 1;
    }
    return run_locked_collection_probe(argv[1]);
}

#else

int main() {
    return 0;
}

#endif
