#include "test_harness.hpp"
#include <thread>
#include <chrono>
#include "../src/notifications/notification_service.hpp"

TEST(notification_parses_otp_payload) {
    nlohmann::json payload = {
        {"type", "otp"},
        {"otp", "482913"},
        {"sender", "HDFC Bank"},
        {"verified", true}
    };

    auto notif = pux::notifications::RelayNotification::from_payload(payload);
    ASSERT_EQ(notif.title, "OTP from HDFC Bank");
    ASSERT_EQ(notif.body, "482913");
    ASSERT_TRUE(notif.code.has_value());
    ASSERT_EQ(notif.code.value(), "482913");
    ASSERT_FALSE(notif.url.has_value());
}

TEST(notification_parses_unverified_otp) {
    nlohmann::json payload = {
        {"type", "otp"},
        {"otp", "123456"},
        {"sender", "Spam Bank"},
        {"verified", false}
    };

    auto notif = pux::notifications::RelayNotification::from_payload(payload);
    ASSERT_EQ(notif.title, "OTP from Spam Bank (unverified)");
    ASSERT_EQ(notif.body, "123456");
}

TEST(notification_parses_forward_confirm_payload) {
    nlohmann::json payload = {
        {"type", "forward_confirm"},
        {"code", "987654"},
        {"forwarding_from", "user@example.com"},
        {"sender", "forwarding-noreply@google.com"},
        {"url", "https://mail.google.com/mail/confirm/xyz"}
    };

    auto notif = pux::notifications::RelayNotification::from_payload(payload);
    ASSERT_EQ(notif.title, "Email forwarding confirmation");
    ASSERT_TRUE(notif.code.has_value());
    ASSERT_EQ(notif.code.value(), "987654");
    ASSERT_TRUE(notif.url.has_value());
    ASSERT_EQ(notif.url.value(), "https://mail.google.com/mail/confirm/xyz");
}

TEST(notification_validates_confirmation_url_whitelist) {
    // Valid Google confirmation hosts
    ASSERT_TRUE(pux::notifications::RelayNotification::validate_confirmation_url(
        "https://mail.google.com/mail/confirm"
    ).has_value());
    ASSERT_TRUE(pux::notifications::RelayNotification::validate_confirmation_url(
        "https://mail-settings.google.com/settings/confirm"
    ).has_value());

    // Disallowed hosts
    ASSERT_FALSE(pux::notifications::RelayNotification::validate_confirmation_url(
        "https://evil.com/phish"
    ).has_value());
    ASSERT_FALSE(pux::notifications::RelayNotification::validate_confirmation_url(
        "https://google.com/mail"
    ).has_value());

    // Insecure HTTP disallowed
    ASSERT_FALSE(pux::notifications::RelayNotification::validate_confirmation_url(
        "http://mail.google.com/mail/confirm"
    ).has_value());

    // Port disallowed
    ASSERT_FALSE(pux::notifications::RelayNotification::validate_confirmation_url(
        "https://mail.google.com:8443/mail/confirm"
    ).has_value());

    // Userinfo disallowed
    ASSERT_FALSE(pux::notifications::RelayNotification::validate_confirmation_url(
        "https://user:pass@mail.google.com/mail/confirm"
    ).has_value());
}

TEST(notification_codes_in_memory_cache) {
    pux::notifications::NotificationCodes codes;

    codes.put(101, "code101");
    codes.put(102, "code102");

    ASSERT_EQ(codes.size(), 2);

    auto taken = codes.take(101);
    ASSERT_TRUE(taken.has_value());
    ASSERT_EQ(taken.value(), "code101");

    // Take removes the code
    ASSERT_EQ(codes.size(), 1);
    ASSERT_FALSE(codes.take(101).has_value());

    codes.remove(102);
    ASSERT_EQ(codes.size(), 0);
}

TEST(notification_service_handles_assigned_id_and_signals) {
    std::string opened_url;
    bool window_activated = false;

    pux::notifications::NotificationService service([&opened_url](const std::string& url) {
        opened_url = url;
        return true;
    });

    service.set_window_activator([&window_activated]() {
        window_activated = true;
    });

    // Put code under daemon-assigned ID 42
    service.codes().put(42, "987321");
    ASSERT_EQ(service.codes().size(), 1);

    // Invoke action "copy_code"
    service.on_action_invoked(42, "copy_code");
    // Code should have been taken
    ASSERT_EQ(service.codes().size(), 0);

    // Default action without URL triggers window activation
    service.on_action_invoked(99, "default");
    ASSERT_TRUE(window_activated);

    // Test dismissal / notification closed signal
    service.codes().put(100, "111222");
    ASSERT_EQ(service.codes().size(), 1);
    service.on_notification_closed(100, 1);
    ASSERT_EQ(service.codes().size(), 0);
}

TEST(notification_payload_actions_expire_without_daemon_close_and_clear) {
    using namespace std::chrono_literals;
    int opened = 0;
    pux::notifications::NotificationService service([&](const std::string&) { ++opened; return true; }, 40ms);
    auto notification = pux::notifications::RelayNotification::from_payload({
        {"type", "forward_confirm"}, {"code", "123456"}, {"url", "https://mail.google.com/mail/confirm"}});
    service.record_delivered(42, notification);
    ASSERT_EQ(service.pending_count(), 1);
    ASSERT_EQ(service.codes().size(), 1);
    auto deadline = std::chrono::steady_clock::now() + 1s;
    while (service.pending_count() && std::chrono::steady_clock::now() < deadline) {
        while (g_main_context_iteration(nullptr, FALSE)) {}
        std::this_thread::sleep_for(2ms);
    }
    ASSERT_EQ(service.pending_count(), 0);
    ASSERT_EQ(service.codes().size(), 0);
    service.on_action_invoked(42, "default");
    ASSERT_EQ(opened, 0);
    pux::notifications::NotificationService bounded(nullptr, 15s);
    for (uint32_t i = 1; i <= 300; ++i) bounded.record_delivered(i, notification);
    ASSERT_EQ(bounded.pending_count(), 256);
    ASSERT_EQ(bounded.codes().size(), 256);
    bounded.clear();
    ASSERT_EQ(bounded.pending_count(), 0);
    ASSERT_EQ(bounded.codes().size(), 0);
}
