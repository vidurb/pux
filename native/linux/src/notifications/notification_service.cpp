#include "notification_service.hpp"
#include "../clipboard/sensitive_clipboard.hpp"
#include <gio/gio.h>
#include <iostream>
#include <algorithm>

namespace pux {
namespace notifications {

const std::vector<std::string> RelayNotification::kAllowedConfirmationHosts = {
    "mail.google.com",
    "mail-settings.google.com"
};

std::optional<std::string> RelayNotification::validate_confirmation_url(const std::string& raw_url) {
    if (raw_url.empty()) return std::nullopt;

    std::string scheme = "https://";
    if (raw_url.rfind(scheme, 0) != 0) {
        return std::nullopt;
    }

    std::string rest = raw_url.substr(scheme.length());
    if (rest.find('@') != std::string::npos) return std::nullopt; // Userinfo disallowed

    std::string host_port;
    size_t slash = rest.find('/');
    if (slash != std::string::npos) {
        host_port = rest.substr(0, slash);
    } else {
        host_port = rest;
    }

    if (host_port.find(':') != std::string::npos) return std::nullopt; // Port disallowed

    for (const auto& allowed : kAllowedConfirmationHosts) {
        if (host_port == allowed) {
            return raw_url;
        }
    }

    return std::nullopt;
}

RelayNotification RelayNotification::from_payload(const nlohmann::json& payload) {
    std::string type = "otp";
    if (payload.contains("type") && payload["type"].is_string()) {
        type = payload["type"].get<std::string>();
    }

    std::string sender = "Unknown sender";
    if (payload.contains("sender") && payload["sender"].is_string()) {
        sender = payload["sender"].get<std::string>();
    }

    RelayNotification notif;

    if (type == "forward_confirm") {
        notif.title = "Email forwarding confirmation";
        std::vector<std::string> lines;

        if (payload.contains("forwarding_from") && payload["forwarding_from"].is_string()) {
            lines.push_back("Forwarding from " + payload["forwarding_from"].get<std::string>());
        }
        if (payload.contains("code") && payload["code"].is_string()) {
            std::string code = payload["code"].get<std::string>();
            notif.code = code;
            lines.push_back("Code: " + code);
        }
        if (payload.contains("url") && payload["url"].is_string()) {
            std::string raw_url = payload["url"].get<std::string>();
            auto valid_url = validate_confirmation_url(raw_url);
            if (valid_url.has_value()) {
                notif.url = valid_url;
                lines.push_back(raw_url);
            }
        }
        if (!payload.contains("forwarding_from") || payload["forwarding_from"].is_null()) {
            lines.push_back("From " + sender);
        }

        std::string body;
        for (size_t i = 0; i < lines.size(); ++i) {
            if (i > 0) body += "\n";
            body += lines[i];
        }
        notif.body = body;
    } else {
        std::string otp = "???";
        if (payload.contains("otp") && payload["otp"].is_string()) {
            otp = payload["otp"].get<std::string>();
        }
        std::string marker;
        if (payload.contains("verified") && payload["verified"].is_boolean() && !payload["verified"].get<bool>()) {
            marker = " (unverified)";
        }
        notif.title = "OTP from " + sender + marker;
        notif.body = otp;
        notif.code = otp;
    }

    return notif;
}

void NotificationCodes::put(uint32_t id, const std::string& code) {
    purge_expired();
    codes_[id] = Entry{
        code,
        std::chrono::steady_clock::now() + lifetime_
    };
}

std::optional<std::string> NotificationCodes::take(uint32_t id) {
    purge_expired();
    auto it = codes_.find(id);
    if (it == codes_.end()) return std::nullopt;
    std::string code = it->second.code;
    codes_.erase(it);
    return code;
}

void NotificationCodes::remove(uint32_t id) {
    codes_.erase(id);
}

size_t NotificationCodes::size() {
    purge_expired();
    return codes_.size();
}

void NotificationCodes::purge_expired() {
    auto now = std::chrono::steady_clock::now();
    for (auto it = codes_.begin(); it != codes_.end();) {
        if (it->second.expires_at <= now) {
            it = codes_.erase(it);
        } else {
            ++it;
        }
    }
}

namespace {

bool default_url_opener(const std::string& url) {
    GError* err = nullptr;
    gboolean res = g_app_info_launch_default_for_uri(url.c_str(), nullptr, &err);
    if (err) {
        g_error_free(err);
        return false;
    }
    return res == TRUE;
}

} // namespace

NotificationService::NotificationService(UrlOpener url_opener, std::chrono::milliseconds lifetime)
    : codes_(lifetime), url_opener_(url_opener ? std::move(url_opener) : default_url_opener), lifetime_(lifetime) {
    GError* err = nullptr;
    bus_ = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &err);
    if (bus_) {
        subscribe_signals();
    } else if (err) {
        g_error_free(err);
    }
}

NotificationService::~NotificationService() {
    clear();
    unsubscribe_signals();
    if (bus_) {
        g_object_unref(bus_);
        bus_ = nullptr;
    }
}

void NotificationService::subscribe_signals() {
    if (!bus_) return;

    action_sub_id_ = g_dbus_connection_signal_subscribe(
        bus_,
        "org.freedesktop.Notifications",
        "org.freedesktop.Notifications",
        "ActionInvoked",
        "/org/freedesktop/Notifications",
        nullptr,
        G_DBUS_SIGNAL_FLAGS_NONE,
        +[](GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*, GVariant* params, gpointer user_data) {
            auto* self = static_cast<NotificationService*>(user_data);
            if (!self || !params) return;
            guint32 id = 0;
            const gchar* action_key = nullptr;
            g_variant_get(params, "(u&s)", &id, &action_key);
            if (action_key) {
                self->on_action_invoked(id, std::string(action_key));
            }
        },
        this,
        nullptr
    );

    closed_sub_id_ = g_dbus_connection_signal_subscribe(
        bus_,
        "org.freedesktop.Notifications",
        "org.freedesktop.Notifications",
        "NotificationClosed",
        "/org/freedesktop/Notifications",
        nullptr,
        G_DBUS_SIGNAL_FLAGS_NONE,
        +[](GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*, GVariant* params, gpointer user_data) {
            auto* self = static_cast<NotificationService*>(user_data);
            if (!self || !params) return;
            guint32 id = 0;
            guint32 reason = 0;
            g_variant_get(params, "(uu)", &id, &reason);
            self->on_notification_closed(id, reason);
        },
        this,
        nullptr
    );
}

void NotificationService::unsubscribe_signals() {
    if (!bus_) return;
    if (action_sub_id_ > 0) {
        g_dbus_connection_signal_unsubscribe(bus_, action_sub_id_);
        action_sub_id_ = 0;
    }
    if (closed_sub_id_ > 0) {
        g_dbus_connection_signal_unsubscribe(bus_, closed_sub_id_);
        closed_sub_id_ = 0;
    }
}

bool NotificationService::is_daemon_available() {
    if (!bus_) return false;

    GError* err = nullptr;
    GVariant* reply = g_dbus_connection_call_sync(
        bus_, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "NameHasOwner",
        g_variant_new("(s)", "org.freedesktop.Notifications"), G_VARIANT_TYPE("(b)"),
        G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &err
    );

    if (!reply) {
        if (err) g_error_free(err);
        return false;
    }

    gboolean has_owner = FALSE;
    g_variant_get(reply, "(b)", &has_owner);
    g_variant_unref(reply);
    return has_owner == TRUE;
}

namespace {
GVariant* notification_params(uint32_t replaces_id, const RelayNotification& notif) {
    GVariantBuilder actions_builder;
    g_variant_builder_init(&actions_builder, G_VARIANT_TYPE("as"));

    // Standard action to activate the app
    g_variant_builder_add(&actions_builder, "s", "default");
    g_variant_builder_add(&actions_builder, "s", "Open");

    // Copy code action if code is present
    if (notif.code.has_value() && !notif.code->empty()) {
        g_variant_builder_add(&actions_builder, "s", "copy_code");
        g_variant_builder_add(&actions_builder, "s", "Copy code");
    }

    GVariantBuilder hints_builder;
    g_variant_builder_init(&hints_builder, G_VARIANT_TYPE("a{sv}"));

    gchar* escaped_body = g_markup_escape_text(notif.body.c_str(), static_cast<gssize>(notif.body.size()));
    GVariant* params = g_variant_new(
        "(susssasa{sv}i)",
        "pux",                                          // app_name
        static_cast<guint32>(replaces_id),              // replaces_id
        "xyz.vidur.pux",                                // app_icon
        notif.title.c_str(),                            // summary
        escaped_body ? escaped_body : "",               // body
        &actions_builder,                               // actions
        &hints_builder,                                 // hints
        -1                                              // timeout
    );
    g_free(escaped_body);
    return params;

}
}

uint32_t NotificationService::send_dbus_notify(uint32_t replaces_id, const RelayNotification& notif) {
    if (!bus_) return 0;
    GError* err = nullptr;
    GVariant* reply = g_dbus_connection_call_sync(
        bus_,
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
        notification_params(replaces_id, notif),
        G_VARIANT_TYPE("(u)"),
        G_DBUS_CALL_FLAGS_NONE,
        10000, // 10 second timeout matching desktop_delivery_service
        nullptr,
        &err
    );

    if (!reply) {
        if (err) g_error_free(err);
        return 0;
    }

    guint32 assigned_id = 0;
    g_variant_get(reply, "(u)", &assigned_id);
    g_variant_unref(reply);
    return assigned_id;
}

void NotificationService::show_async(const RelayNotification& notification, std::function<bool()> valid, std::function<void(bool)> done) {
    if (!bus_) { done(false); return; }
    struct Request {
        std::shared_ptr<NotificationService> self;
        RelayNotification notification;
        std::function<bool()> valid;
        std::function<void(bool)> done;
    };
    auto* request = new Request{shared_from_this(), notification, std::move(valid), std::move(done)};
    g_dbus_connection_call(bus_, "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications", "Notify", notification_params(0, notification),
        G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 10000, nullptr,
        +[](GObject* source, GAsyncResult* result, gpointer data) {
            std::unique_ptr<Request> request(static_cast<Request*>(data));
            GError* error = nullptr;
            GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
            guint32 id = 0;
            if (reply) { g_variant_get(reply, "(u)", &id); g_variant_unref(reply); }
            if (error) g_error_free(error);
            if (!request->valid()) return;
            if (id) request->self->record_delivered(id, request->notification);
            request->done(id != 0);
        }, request);
}

bool NotificationService::show(const RelayNotification& notification) {
    uint32_t assigned_id = send_dbus_notify(0, notification);
    if (assigned_id == 0) {
        return false;
    }

    record_delivered(assigned_id, notification);
    return true;
}

void NotificationService::on_action_invoked(uint32_t id, const std::string& action_key) {
    expire();
    schedule_expiry();
    if (action_key == "copy_code") {
        auto code = codes_.take(id);
        if (code.has_value() && !code->empty()) {
            clipboard::SensitiveClipboard::instance().copy(code.value());
        }
    } else if (action_key == "default" || action_key.empty()) {
        auto it = pending_notifications_.find(id);
        if (it != pending_notifications_.end() && it->second.url.has_value()) {
            if (url_opener_) {
                url_opener_(it->second.url.value());
            }
        } else if (show_window_cb_) {
            show_window_cb_();
        }
    }
}

void NotificationService::on_notification_closed(uint32_t id, uint32_t reason) {
    (void)reason;
    codes_.remove(id);
    pending_notifications_.erase(id);
    schedule_expiry();
}

void NotificationService::clear() {
    if (expiry_timer_) { g_source_remove(expiry_timer_); expiry_timer_ = 0; }
    pending_notifications_.clear();
    codes_.clear();
}

void NotificationService::record_delivered(uint32_t id, const RelayNotification& notification) {
    if (notification.code && !notification.code->empty()) codes_.put(id, *notification.code);
    else codes_.remove(id);
    pending_notifications_[id] = {notification.url, std::chrono::steady_clock::now() + lifetime_};
    while (pending_notifications_.size() > 256) {
        auto oldest = std::min_element(pending_notifications_.begin(), pending_notifications_.end(),
            [](const auto& a, const auto& b) { return a.second.expires_at < b.second.expires_at; });
        codes_.remove(oldest->first);
        pending_notifications_.erase(oldest);
    }
    schedule_expiry();
}

void NotificationService::expire() {
    auto now = std::chrono::steady_clock::now();
    for (auto it = pending_notifications_.begin(); it != pending_notifications_.end();) {
        if (it->second.expires_at <= now) { codes_.remove(it->first); it = pending_notifications_.erase(it); }
        else ++it;
    }
    codes_.purge_expired();
}

void NotificationService::schedule_expiry() {
    if (expiry_timer_) { g_source_remove(expiry_timer_); expiry_timer_ = 0; }
    if (pending_notifications_.empty()) return;
    auto earliest = std::min_element(pending_notifications_.begin(), pending_notifications_.end(),
        [](const auto& a, const auto& b) { return a.second.expires_at < b.second.expires_at; });
    auto remaining = earliest->second.expires_at - std::chrono::steady_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(remaining).count() + 1;
    expiry_timer_ = g_timeout_add(static_cast<guint>(std::max<int64_t>(1, ms)), +[](gpointer data) -> gboolean {
        auto* self = static_cast<NotificationService*>(data);
        self->expiry_timer_ = 0; self->expire(); self->schedule_expiry();
        return G_SOURCE_REMOVE;
    }, this);
}

} // namespace notifications
} // namespace pux
