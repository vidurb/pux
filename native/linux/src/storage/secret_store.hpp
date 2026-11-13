#pragma once

#include <string>
#include <map>
#include <memory>
#include <optional>
#include <stdexcept>
#include <utility>

namespace pux {
namespace storage {

class StorageException : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class KeyringUnavailableException : public StorageException {
public:
    KeyringUnavailableException()
        : StorageException(
            "Secret Service provider (GNOME Keyring, KWallet or KeePassXC) is not running on the session bus. "
            "pux requires an active Secret Service to store private keys securely."
        ) {}
    explicit KeyringUnavailableException(const std::string& msg)
        : StorageException(msg) {}
};

class KeyringLockedException : public StorageException {
public:
    KeyringLockedException()
        : StorageException(
            "The Secret Service keyring is locked. Please unlock your keyring to use pux."
        ) {}
    explicit KeyringLockedException(const std::string& msg)
        : StorageException(msg) {}
};

class KeyringCorruptException : public StorageException {
public:
    KeyringCorruptException()
        : StorageException(
            "Enrollment data in the keyring is corrupted. Unlock the keyring and retry, or contact support."
        ) {}
};

class LegacyEnrollmentPendingException : public StorageException {
public:
    LegacyEnrollmentPendingException()
        : StorageException(
            "A legacy Flutter enrollment item exists in the keyring but could not be migrated. "
            "Unlock the keyring and retry before importing or creating a new relay."
        ) {}
};

// Abstract secret storage interface
class SecretStore {
public:
    virtual ~SecretStore() = default;

    virtual std::optional<std::string> read(const std::string& key) = 0;
    virtual void write(const std::string& key, const std::string& value) = 0;
    virtual void delete_key(const std::string& key) = 0;
    virtual void clear() = 0;
    virtual void replace_all(std::map<std::string, std::string> data) = 0;
    virtual bool contains_key(const std::string& key) = 0;
    virtual std::map<std::string, std::string> read_all() = 0;
};

// In-memory store for unit testing only
class MemorySecretStore : public SecretStore {
public:
    void replace(std::map<std::string, std::string> data) { data_ = std::move(data); }
    std::optional<std::string> read(const std::string& key) override;
    void write(const std::string& key, const std::string& value) override;
    void delete_key(const std::string& key) override;
    void clear() override;
    void replace_all(std::map<std::string, std::string> data) override;
    bool contains_key(const std::string& key) override;
    std::map<std::string, std::string> read_all() override;

private:
    std::map<std::string, std::string> data_;
};

class SecretServiceStore : public SecretStore {
public:
    enum class Status {
        Available,
        Locked,
        MissingService
    };

    enum class ReadState {
        None,
        Ok,
        Locked,
        Unavailable,
        Corrupt,
        Empty
    };

    explicit SecretServiceStore(std::string application_id = "xyz.vidur.pux");

    std::optional<std::string> read(const std::string& key) override;
    void write(const std::string& key, const std::string& value) override;
    void delete_key(const std::string& key) override;
    void clear() override;
    void replace_all(std::map<std::string, std::string> data) override;
    bool contains_key(const std::string& key) override;
    std::map<std::string, std::string> read_all() override;

    static bool is_secret_service_available();
    static Status check_status();

    ReadState last_read_state() const { return read_state_; }
    bool legacy_enrollment_pending() const { return legacy_pending_; }

    const std::string& schema_name() const { return schema_name_; }
    const std::string& account_attribute() const { return account_attribute_; }
    const std::string& item_label() const { return item_label_; }

private:
    std::string application_id_;
    std::string schema_name_;
    std::string account_attribute_;
    std::string item_label_;

    ReadState read_state_ = ReadState::None;
    bool legacy_pending_ = false;
    bool prepared_ = false;
    bool migrating_ = false;

    void require_writable() const;
    void ensure_prepared();
    std::map<std::string, std::string> fetch_from_keyring();
    void store_to_keyring(const std::map<std::string, std::string>& data);

#ifdef HAVE_LIBSECRET
    class MigratingScope {
    public:
        explicit MigratingScope(SecretServiceStore& store) : store_(store) { store_.migrating_ = true; }
        ~MigratingScope() { store_.migrating_ = false; }
        MigratingScope(const MigratingScope&) = delete;
        MigratingScope& operator=(const MigratingScope&) = delete;

    private:
        SecretServiceStore& store_;
    };

    std::optional<std::string> lookup_native_secret();
    std::optional<std::string> find_legacy_enrollment_json();
    bool write_native_json(const std::string& json);
    bool migrate_legacy_to_native(
        const std::string& legacy_blob,
        const std::map<std::string, std::string>& data
    );
#endif
};

std::shared_ptr<SecretStore> create_default_secret_store();

} // namespace storage
} // namespace pux
