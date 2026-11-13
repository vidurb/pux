#pragma once

#include <string>
#include <vector>
#include <map>
#include <memory>
#include <chrono>
#include <optional>
#include <functional>
#include <gio/gio.h>
#include "../vendor/json.hpp"

namespace pux {
namespace notifications {

struct RelayNotification {
    std::string title;
    std::string body;
    std::optional<std::string> code;
    std::optional<std::string> url;

    static RelayNotification from_payload(const nlohmann::json& payload);
    static std::optional<std::string> validate_confirmation_url(const std::string& raw_url);
    static const std::vector<std::string> kAllowedConfirmationHosts;
};

// In-memory code cache for notification action "Copy code"
// Codes are never saved to disk and expire after 15 minutes.
class NotificationCodes {
public:
    explicit NotificationCodes(std::chrono::milliseconds lifetime = std::chrono::minutes(15)) : lifetime_(lifetime) {}
    static constexpr std::chrono::minutes kCodeLifetime{15};

    void put(uint32_t id, const std::string& code);
    std::optional<std::string> take(uint32_t id);
    void remove(uint32_t id);
    size_t size();
    void purge_expired();
    void clear() { codes_.clear(); }

private:
    struct Entry {
        std::string code;
        std::chrono::steady_clock::time_point expires_at;
    };
    std::map<uint32_t, Entry> codes_;
    std::chrono::milliseconds lifetime_;
};

class NotificationService : public std::enable_shared_from_this<NotificationService> {
public:
    using UrlOpener = std::function<bool(const std::string& url)>;
    using ShowWindowCallback = std::function<void()>;

    explicit NotificationService(UrlOpener url_opener = nullptr, std::chrono::milliseconds lifetime = std::chrono::minutes(15));
    virtual ~NotificationService();

    virtual bool is_daemon_available();
    virtual bool show(const RelayNotification& notification);
    virtual void show_async(const RelayNotification& notification, std::function<bool()> valid, std::function<void(bool)> done);

    void set_window_activator(ShowWindowCallback callback) {
        show_window_cb_ = std::move(callback);
    }

    void set_url_opener(UrlOpener opener) {
        url_opener_ = std::move(opener);
    }

    NotificationCodes& codes() { return codes_; }

    void on_action_invoked(uint32_t id, const std::string& action_key);
    void on_notification_closed(uint32_t id, uint32_t reason);

    void record_delivered(uint32_t id, const RelayNotification& notification);
    void clear();
    size_t pending_count() const { return pending_notifications_.size(); }

private:
    NotificationCodes codes_;
    UrlOpener url_opener_;
    ShowWindowCallback show_window_cb_;
    struct PendingAction { std::optional<std::string> url; std::chrono::steady_clock::time_point expires_at; };
    std::map<uint32_t, PendingAction> pending_notifications_;
    std::chrono::milliseconds lifetime_;
    guint expiry_timer_ = 0;
    void schedule_expiry();
    void expire();

    GDBusConnection* bus_ = nullptr;
    guint action_sub_id_ = 0;
    guint closed_sub_id_ = 0;

    void subscribe_signals();
    void unsubscribe_signals();
    uint32_t send_dbus_notify(uint32_t replaces_id, const RelayNotification& notif);
};

} // namespace notifications
} // namespace pux
