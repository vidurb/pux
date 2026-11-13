#include "test_harness.hpp"
#include "../src/delivery/desktop_delivery_service.hpp"
#include "../src/storage/registration_outcome.hpp"
#include "../src/crypto/crypto.hpp"
#include <glib.h>
#include <mutex>
#include <thread>
#include <atomic>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

namespace {

class MockNotificationService : public pux::notifications::NotificationService {
public:
    bool should_succeed = true;
    int show_count = 0;
    std::vector<pux::notifications::RelayNotification> shown;

    bool show(const pux::notifications::RelayNotification& notification) override {
        show_count++;
        shown.push_back(notification);
        return should_succeed;
    }
    void show_async(const pux::notifications::RelayNotification& notification,
                    std::function<bool()> valid, std::function<void(bool)> done) override {
        if (valid()) done(show(notification));
    }
};

class MockHttpTransportForDelivery : public pux::api::HttpTransport {
public:
    std::vector<std::string> acks;
    std::mutex mutex;
    std::atomic<int> polls{0};
    std::atomic<int> registrations{0};
    std::vector<std::string> ack_snapshot() { std::lock_guard<std::mutex> lock(mutex); return acks; }
    void wait_ack() { for (int i=0; i<100 && ack_snapshot().empty(); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(5)); }

    pux::api::HttpResponse request(
        const std::string& method,
        const std::string& url,
        const std::vector<std::string>& /*headers*/,
        const std::string& /*body*/,
        long /*timeout_seconds*/
    ) override {
        if (method == "POST" && url.find("/record/devices") != std::string::npos) {
            ++registrations;
            return {200, "{\"device_id\":\"dev-100\"}"};
        }
        if (method == "GET" && url.find("/record/deliveries") != std::string::npos) {
            ++polls;
            return {200, "{\"deliveries\":[]}"};
        }
        if (method == "DELETE" && url.find("/record/deliveries/") != std::string::npos) {
            size_t slash = url.rfind('/');
            std::lock_guard<std::mutex> lock(mutex);
            acks.push_back(url.substr(slash + 1));
            return {200, "{}"};
        }
        return {200, "{}"};
    }
};

} // namespace

TEST(delivery_service_processes_valid_envelope) {
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();

    auto mem_store = std::make_shared<pux::storage::MemorySecretStore>();
    auto rs = std::make_shared<pux::storage::RecordStore>(mem_store);
    nlohmann::json enrollment = {
        {"v", 1},
        {"record_id", "11111111-2222-3333-4444-555555555555"},
        {"private_key", kp.private_key},
        {"public_key", kp.public_key},
        {"inbox", "inbox@pux.xyz"},
        {"server", "http://127.0.0.1:1"}
    };
    rs->save_enrollment(enrollment);

    auto mock_http = std::make_shared<MockHttpTransportForDelivery>();
    auto api = std::make_shared<pux::api::ApiClient>(mock_http);
    auto notif_service = std::make_shared<MockNotificationService>();

    auto delivery = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, api, notif_service);
    delivery->start();

    // Create encrypted envelope
    std::string plaintext = "{\"type\":\"otp\",\"otp\":\"789012\",\"sender\":\"SBI\"}";
    std::string ciphertext = pux::crypto::seal_box(plaintext, kp.public_key);
    nlohmann::json envelope = {{"ciphertext", ciphertext}};

    // Deliver
    delivery->handle_delivery("del-001", envelope);

    // Should have shown notification
    ASSERT_EQ(notif_service->show_count, 1);
    ASSERT_EQ(notif_service->shown[0].body, "789012");

    // Should have acknowledged to server
    mock_http->wait_ack();
    ASSERT_EQ(mock_http->ack_snapshot().size(), 1);
    ASSERT_EQ(mock_http->ack_snapshot()[0], "del-001");

    // On Linux, shown codes are also kept in recent
    ASSERT_EQ(delivery->recent_deliveries().size(), 1);
    ASSERT_EQ(delivery->held_deliveries().size(), 0);
}

TEST(delivery_start_reregisters_saved_and_pruned_device_on_each_launch) {
    using namespace std::chrono_literals;
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();
    auto rs = std::make_shared<pux::storage::RecordStore>(std::make_shared<pux::storage::MemorySecretStore>());
    rs->save_enrollment({{"v",1},{"record_id","11111111-2222-3333-4444-555555555555"},
        {"private_key",kp.private_key},{"public_key",kp.public_key},{"inbox","inbox@pux.xyz"},{"server","http://127.0.0.1:1"}});
    rs->save_device_id("pruned-id");
    auto transport = std::make_shared<MockHttpTransportForDelivery>();
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, std::make_shared<pux::api::ApiClient>(transport), std::make_shared<MockNotificationService>());
    for (int launch = 1; launch <= 2; ++launch) {
        int polls_before = transport->polls.load();
        service->start();
        auto deadline = std::chrono::steady_clock::now() + 2s;
        while (std::chrono::steady_clock::now() < deadline &&
               (transport->registrations.load() < launch || transport->polls.load() <= polls_before || rs->device_id().value_or("") != "dev-100")) {
            while (g_main_context_iteration(nullptr, FALSE)) {}
            std::this_thread::sleep_for(2ms);
        }
        ASSERT_EQ(transport->registrations.load(), launch);
        ASSERT_TRUE(transport->polls.load() > polls_before);
        ASSERT_EQ(rs->device_id().value(), "dev-100");
        service->stop();
    }
}

TEST(delivery_service_holds_when_notification_fails) {
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();

    auto mem_store = std::make_shared<pux::storage::MemorySecretStore>();
    auto rs = std::make_shared<pux::storage::RecordStore>(mem_store);
    nlohmann::json enrollment = {
        {"v", 1},
        {"record_id", "11111111-2222-3333-4444-555555555555"},
        {"private_key", kp.private_key},
        {"public_key", kp.public_key},
        {"inbox", "inbox@pux.xyz"},
        {"server", "http://127.0.0.1:1"}
    };
    rs->save_enrollment(enrollment);

    auto mock_http = std::make_shared<MockHttpTransportForDelivery>();
    auto api = std::make_shared<pux::api::ApiClient>(mock_http);
    auto notif_service = std::make_shared<MockNotificationService>();
    notif_service->should_succeed = false; // Simulate missing daemon or notification failure

    auto delivery = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, api, notif_service);
    delivery->start();

    std::string plaintext = "{\"type\":\"otp\",\"otp\":\"345678\",\"sender\":\"Axis Bank\"}";
    std::string ciphertext = pux::crypto::seal_box(plaintext, kp.public_key);
    nlohmann::json envelope = {{"ciphertext", ciphertext}};

    delivery->handle_delivery("del-002", envelope);

    // Should have attempted to show
    ASSERT_EQ(notif_service->show_count, 1);

    // Should NOT have acknowledged since notification was not displayed
    ASSERT_EQ(mock_http->ack_snapshot().size(), 0);

    // Should be in holding
    ASSERT_EQ(delivery->held_deliveries().size(), 1);
    ASSERT_EQ(delivery->held_deliveries()[0].delivery_id, "del-002");
    ASSERT_EQ(delivery->recent_deliveries().size(), 0);
}

TEST(delivery_service_tracks_undecryptable_without_acking) {
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();

    auto mem_store = std::make_shared<pux::storage::MemorySecretStore>();
    auto rs = std::make_shared<pux::storage::RecordStore>(mem_store);
    nlohmann::json enrollment = {
        {"v", 1},
        {"record_id", "11111111-2222-3333-4444-555555555555"},
        {"private_key", kp.private_key},
        {"public_key", kp.public_key},
        {"inbox", "inbox@pux.xyz"},
        {"server", "http://127.0.0.1:1"}
    };
    rs->save_enrollment(enrollment);

    auto mock_http = std::make_shared<MockHttpTransportForDelivery>();
    auto api = std::make_shared<pux::api::ApiClient>(mock_http);
    auto notif_service = std::make_shared<MockNotificationService>();

    auto delivery = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, api, notif_service);
    delivery->start();

    // Envelope with invalid/corrupt ciphertext
    nlohmann::json bad_envelope = {{"ciphertext", "not-a-valid-ciphertext"}};

    delivery->handle_delivery("del-bad", bad_envelope);

    ASSERT_EQ(notif_service->show_count, 0);
    ASSERT_EQ(mock_http->ack_snapshot().size(), 0);
    ASSERT_EQ(delivery->status().undecryptable_count, 1);
}

TEST(delivery_service_registers_device_and_periodic_recheck) {
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();

    auto mem_store = std::make_shared<pux::storage::MemorySecretStore>();
    auto rs = std::make_shared<pux::storage::RecordStore>(mem_store);
    nlohmann::json enrollment = {
        {"v", 1},
        {"record_id", "11111111-2222-3333-4444-555555555555"},
        {"private_key", kp.private_key},
        {"public_key", kp.public_key},
        {"inbox", "inbox@pux.xyz"},
        {"server", "http://127.0.0.1:1"}
    };
    rs->save_enrollment(enrollment);

    auto mock_http = std::make_shared<MockHttpTransportForDelivery>();
    auto api = std::make_shared<pux::api::ApiClient>(mock_http);
    auto notif_service = std::make_shared<MockNotificationService>();

    auto delivery = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, api, notif_service);
    delivery->start();

    // Register device saves device ID
    delivery->register_device();
    ASSERT_TRUE(rs->device_id().has_value());
    ASSERT_EQ(rs->device_id().value(), "dev-100");

    // Periodic poll handles empty deliveries cleanly
    delivery->poll_pending();
    ASSERT_EQ(delivery->held_deliveries().size(), 0);

    // Recheck held with empty queues runs without throwing
    delivery->recheck_held();
    ASSERT_EQ(delivery->held_deliveries().size(), 0);
}

TEST(delivery_service_held_to_recent_recovery_transfers_codes) {
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();

    auto mem_store = std::make_shared<pux::storage::MemorySecretStore>();
    auto rs = std::make_shared<pux::storage::RecordStore>(mem_store);
    nlohmann::json enrollment = {
        {"v", 1},
        {"record_id", "11111111-2222-3333-4444-555555555555"},
        {"private_key", kp.private_key},
        {"public_key", kp.public_key},
        {"inbox", "inbox@pux.xyz"},
        {"server", "http://127.0.0.1:1"}
    };
    rs->save_enrollment(enrollment);

    auto mock_http = std::make_shared<MockHttpTransportForDelivery>();
    auto api = std::make_shared<pux::api::ApiClient>(mock_http);
    auto notif_service = std::make_shared<MockNotificationService>();
    notif_service->should_succeed = false; // Notification initially fails (daemon missing/locked)

    auto delivery = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, api, notif_service);
    delivery->start();

    auto ciphertext = pux::crypto::seal_box("{\"type\":\"otp\",\"otp\":\"123456\",\"sender\":\"HDFC\"}", kp.public_key);
    delivery->handle_delivery("d1", {{"ciphertext", ciphertext}});

    // Initially held because notification failed
    ASSERT_EQ(delivery->held_deliveries().size(), 1);
    ASSERT_EQ(delivery->recent_deliveries().size(), 0);
    ASSERT_EQ(mock_http->ack_snapshot().size(), 0);

    // Daemon recovers and accepts notification
    notif_service->should_succeed = true;
    delivery->recheck_held();

    // After recovery: code must be moved from held to recent, and acknowledged to server
    ASSERT_EQ(delivery->held_deliveries().size(), 0);
    ASSERT_EQ(delivery->recent_deliveries().size(), 1);
    ASSERT_EQ(delivery->recent_deliveries()[0].delivery_id, "d1");
    mock_http->wait_ack();
    ASSERT_EQ(mock_http->ack_snapshot().size(), 1);
    ASSERT_EQ(mock_http->ack_snapshot()[0], "d1");

    // Reconnection MUST NOT clear recent or held codes
    delivery->schedule_reconnect("temporary socket glitch");
    ASSERT_EQ(delivery->recent_deliveries().size(), 1);
    ASSERT_TRUE(delivery->status().state == pux::delivery::DeliveryState::Retrying);
}

TEST(delivery_service_reconnect_preserves_polling_and_expiration_timers) {
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();

    auto mem_store = std::make_shared<pux::storage::MemorySecretStore>();
    auto rs = std::make_shared<pux::storage::RecordStore>(mem_store);
    nlohmann::json enrollment = {
        {"v", 1},
        {"record_id", "11111111-2222-3333-4444-555555555555"},
        {"private_key", kp.private_key},
        {"public_key", kp.public_key},
        {"inbox", "inbox@pux.xyz"},
        {"server", "http://127.0.0.1:1"}
    };
    rs->save_enrollment(enrollment);

    auto mock_http = std::make_shared<MockHttpTransportForDelivery>();
    auto api = std::make_shared<pux::api::ApiClient>(mock_http);
    auto notif_service = std::make_shared<MockNotificationService>();
    notif_service->should_succeed = false; // Hold code

    auto delivery = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, api, notif_service);
    delivery->start();

    // Deliver a held code so recheck timer is started
    auto ciphertext = pux::crypto::seal_box("{\"type\":\"otp\",\"otp\":\"999888\",\"sender\":\"ICICI\"}", kp.public_key);
    delivery->handle_delivery("held-timer-test", {{"ciphertext", ciphertext}});

    uint32_t poll_timer_orig = delivery->periodic_poll_timer_id();
    uint32_t recheck_timer_orig = delivery->recheck_timer_id();

    ASSERT_TRUE(poll_timer_orig != 0);
    ASSERT_TRUE(recheck_timer_orig != 0);
    ASSERT_EQ(delivery->held_deliveries().size(), 1);

    // Socket disconnect triggers schedule_reconnect()
    delivery->schedule_reconnect("peer connection closed");

    // Reconnection timer is scheduled
    ASSERT_TRUE(delivery->reconnect_timer_id() != 0);

    // CRITICAL: Periodic poll timer and recheck expiration timer MUST NOT be cancelled!
    ASSERT_EQ(delivery->periodic_poll_timer_id(), poll_timer_orig);
    ASSERT_EQ(delivery->recheck_timer_id(), recheck_timer_orig);
    ASSERT_EQ(delivery->held_deliveries().size(), 1);

    // When reconnect timer fires, reconnect_socket() is called:
    // It reconnects socket WITHOUT cancelling poll timer, recheck timer, or wiping codes!
    delivery->reconnect_socket();

    ASSERT_EQ(delivery->periodic_poll_timer_id(), poll_timer_orig);
    ASSERT_EQ(delivery->recheck_timer_id(), recheck_timer_orig);
    ASSERT_EQ(delivery->held_deliveries().size(), 1);

    delivery->stop();
}

TEST(delivery_service_reconnects_and_timers_continue_until_expiry) {
    using namespace std::chrono_literals;
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    ASSERT_TRUE(listener >= 0);
    int yes = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    ASSERT_EQ(bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)), 0);
    ASSERT_EQ(listen(listener, 4), 0);
    socklen_t length = sizeof(addr);
    ASSERT_EQ(getsockname(listener, reinterpret_cast<sockaddr*>(&addr), &length), 0);
    std::atomic<int> connections{0};
    std::thread server([&]() {
        for (int i = 0; i < 2; ++i) {
            fd_set fds; FD_ZERO(&fds); FD_SET(listener, &fds);
            timeval timeout{3, 0};
            if (select(listener + 1, &fds, nullptr, nullptr, &timeout) <= 0) break;
            int fd = accept(listener, nullptr, nullptr);
            if (fd < 0) break;
            timeval read_timeout{2, 0};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &read_timeout, sizeof(read_timeout));
            std::string request; char buf[2048];
            while (request.find("\r\n\r\n") == std::string::npos) {
                auto n = recv(fd, buf, sizeof(buf), 0); if (n <= 0) break; request.append(buf, n);
            }
            auto pos = request.find("Sec-WebSocket-Key: ");
            if (pos != std::string::npos) {
                pos += 19;
                auto end = request.find("\r\n", pos);
                auto accept_key = pux::delivery::compute_sec_ws_accept(request.substr(pos, end - pos));
                auto response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept_key + "\r\n\r\n";
                send(fd, response.data(), response.size(), 0);
                ++connections;
                if (i == 0) { const char close_frame[] = {char(0x88), 0}; send(fd, close_frame, 2, 0); }
                else std::this_thread::sleep_for(400ms);
            }
            close(fd);
        }
    });
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();
    auto rs = std::make_shared<pux::storage::RecordStore>(std::make_shared<pux::storage::MemorySecretStore>());
    auto server_url = std::string("http://127.0.0.1:") + std::to_string(ntohs(addr.sin_port));
    rs->save_enrollment({{"v",1},{"record_id","11111111-2222-3333-4444-555555555555"},
        {"private_key",kp.private_key},{"public_key",kp.public_key},{"inbox","inbox@pux.xyz"},{"server",server_url}});
    rs->save_device_id("dev-100");
    auto http = std::make_shared<MockHttpTransportForDelivery>();
    auto notif = std::make_shared<MockNotificationService>();
    pux::delivery::DeliveryTiming timing{200ms, 25ms, 40ms, 400ms};
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, std::make_shared<pux::api::ApiClient>(http), notif, timing);
    bool expiry_published = false;
    bool saw_recent = false;
    int polls_at_disconnect = -1;
    bool polled_while_disconnected = false;
    service->set_status_callback([&](const auto& status) {
        if (status.state == pux::delivery::DeliveryState::Retrying && polls_at_disconnect < 0)
            polls_at_disconnect = http->polls.load();
    });
    service->set_held_callback([&](const auto&, const auto& recent) {
        if (!recent.empty()) saw_recent = true;
        else if (saw_recent) expiry_published = true;
    });
    service->start();
    auto cipher = pux::crypto::seal_box("{\"type\":\"otp\",\"otp\":\"123456\"}", kp.public_key);
    service->handle_delivery("timed", {{"ciphertext",cipher}});
    auto deadline = std::chrono::steady_clock::now() + 3s;
    while (std::chrono::steady_clock::now() < deadline &&
           (connections.load() < 2 || http->polls.load() < 3 || !expiry_published)) {
        while (g_main_context_iteration(nullptr, FALSE)) {}
        if (polls_at_disconnect >= 0 && connections.load() == 1 && http->polls.load() > polls_at_disconnect)
            polled_while_disconnected = true;
        std::this_thread::sleep_for(5ms);
    }
    bool reconnected = connections.load() >= 2;
    bool polled = http->polls.load() >= 3;
    bool expired = expiry_published && service->recent_deliveries().empty();
    service->stop();
    server.join(); close(listener);
    ASSERT_TRUE(reconnected);
    ASSERT_TRUE(polled);
    ASSERT_TRUE(polled_while_disconnected);
    ASSERT_TRUE(expired);
}

#include "../src/ui/removal_flow.hpp"
TEST(removal_decisions_preserve_or_clear_enrollment) {
    using namespace pux::ui;
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();
    auto rs = std::make_shared<pux::storage::RecordStore>(std::make_shared<pux::storage::MemorySecretStore>());
    auto enroll = [&]() { rs->save_enrollment({{"v",1},{"record_id","11111111-2222-3333-4444-555555555555"},
        {"private_key",kp.private_key},{"public_key",kp.public_key},{"inbox","inbox@pux.xyz"},{"server","http://127.0.0.1:1"}}); };
    enroll();
    int resumes = 0, retries = 0;
    auto clear = [&]() { rs->clear(); };
    auto resume = [&]() { ++resumes; };
    auto retry = [&]() { ++retries; };
    struct FlakyDelete : pux::api::HttpTransport {
        int calls = 0;
        pux::api::HttpResponse request(const std::string& method, const std::string& url,
                const std::vector<std::string>&, const std::string&, long) override {
            if (method != "DELETE" || url.find("/api/v1/record") == std::string::npos) return {400, "wrong request"};
            return ++calls == 1 ? pux::api::HttpResponse{503, "offline"} : pux::api::HttpResponse{204, ""};
        }
    };
    auto transport = std::make_shared<FlakyDelete>();
    pux::api::ApiClient api(transport);
    auto server_call = [&]() { api.delete_record(rs->server_url(), rs->record_id().value()); };
    auto failed = attempt_removal(server_call);
    ASSERT_FALSE(failed.succeeded); ASSERT_TRUE(failed.error.find("offline") != std::string::npos);
    finish_removal(RemovalResult::Cancel, clear, resume, retry);
    ASSERT_TRUE(rs->is_enrolled()); ASSERT_EQ(resumes, 1);
    finish_removal(RemovalResult::Retry, clear, resume, retry);
    ASSERT_TRUE(rs->is_enrolled()); ASSERT_EQ(retries, 1);
    ASSERT_TRUE(attempt_removal(server_call).succeeded); ASSERT_EQ(transport->calls, 2);
    finish_removal(RemovalResult::ForgetLocally, clear, resume, retry);
    ASSERT_FALSE(rs->is_enrolled());
    enroll();
    finish_removal(RemovalResult::Success, clear, resume, retry);
    ASSERT_FALSE(rs->is_enrolled());
}

namespace {
class DelayedRegistration : public pux::api::HttpTransport {
public:
    std::atomic<bool> entered{false};
    std::atomic<bool> release{false};
    std::atomic<bool> returned{false};
    pux::api::HttpResponse request(const std::string&, const std::string&, const std::vector<std::string>&,
                                  const std::string&, long) override {
        entered = true;
        while (!release.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        returned = true;
        return {200, "{\"device_id\":\"old-device\"}"};
    }
};
class DeferredNotification : public pux::notifications::NotificationService {
public:
    std::function<bool()> valid;
    std::function<void(bool)> completion;
    void show_async(const pux::notifications::RelayNotification&, std::function<bool()> v,
                    std::function<void(bool)> done) override { valid = std::move(v); completion = std::move(done); }
    void complete() { if (valid && valid()) completion(true); }
};
}

TEST(delivery_stop_rejects_stale_registration_and_notification) {
    using namespace std::chrono_literals;
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();
    auto rs = std::make_shared<pux::storage::RecordStore>(std::make_shared<pux::storage::MemorySecretStore>());
    auto enroll = [&](const char* id) { rs->save_enrollment({{"v",1},{"record_id",id},
        {"private_key",kp.private_key},{"public_key",kp.public_key},{"inbox","inbox@pux.xyz"},{"server","http://127.0.0.1:1"}}); };
    enroll("11111111-2222-3333-4444-555555555555");
    auto http = std::make_shared<DelayedRegistration>();
    auto notif = std::make_shared<DeferredNotification>();
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, std::make_shared<pux::api::ApiClient>(http), notif);
    service->start();
    for (int i = 0; i < 200 && !http->entered; ++i) std::this_thread::sleep_for(1ms);
    bool entered = http->entered.load();
    auto cipher = pux::crypto::seal_box("{\"type\":\"otp\",\"otp\":\"123456\"}", kp.public_key);
    service->handle_delivery("old", {{"ciphertext",cipher}});
    bool deferred = static_cast<bool>(notif->completion);
    service->suspend();
    bool held_during_removal = service->held_deliveries().size() == 1;
    service->stop();
    rs->clear();
    enroll("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    std::atomic<bool> registration_finished{false};
    std::thread waiter([&]() { service->wait_for_registration(); registration_finished = true; });
    std::this_thread::sleep_for(20ms);
    bool waited = !registration_finished.load();
    http->release = true;
    waiter.join();
    for (int i = 0; i < 200 && !http->returned; ++i) std::this_thread::sleep_for(1ms);
    for (int i = 0; i < 30; ++i) { while (g_main_context_iteration(nullptr, FALSE)) {} std::this_thread::sleep_for(2ms); }
    notif->complete();
    ASSERT_TRUE(entered); ASSERT_TRUE(deferred); ASSERT_TRUE(held_during_removal);
    ASSERT_TRUE(waited); ASSERT_TRUE(http->returned.load());
    ASSERT_EQ(service->registered_device_id("11111111-2222-3333-4444-555555555555"), "old-device");
    ASSERT_FALSE(rs->device_id().has_value());
    ASSERT_EQ(rs->record_id().value(), "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    ASSERT_TRUE(service->recent_deliveries().empty());
}

TEST(delivery_stop_clears_notification_actions) {
    auto notifications = std::make_shared<MockNotificationService>();
    pux::notifications::RelayNotification payload;
    payload.body = "sensitive body";
    payload.code = "123456";
    payload.url = "https://mail.google.com/mail/confirm";
    notifications->record_delivered(42, payload);
    auto rs = std::make_shared<pux::storage::RecordStore>(std::make_shared<pux::storage::MemorySecretStore>());
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, std::make_shared<pux::api::ApiClient>(std::make_shared<MockHttpTransportForDelivery>()), notifications);
    service->stop();
    ASSERT_EQ(notifications->pending_count(), 0);
    ASSERT_EQ(notifications->codes().size(), 0);
}

TEST(delivery_keyring_failure_leaves_service_stopped_for_retry) {
    class LockableStore : public pux::storage::MemorySecretStore {
    public:
        bool locked = false;
        std::optional<std::string> read(const std::string& key) override {
            if (locked) throw pux::storage::KeyringLockedException();
            return MemorySecretStore::read(key);
        }
    };
    pux::crypto::init();
    auto key = pux::crypto::generate_key_pair();
    auto secrets = std::make_shared<LockableStore>();
    auto rs = std::make_shared<pux::storage::RecordStore>(secrets);
    rs->save_enrollment({{"v",1},{"record_id","11111111-2222-3333-4444-555555555555"},
        {"private_key",key.private_key},{"public_key",key.public_key},{"inbox","inbox@pux.xyz"},{"server","http://127.0.0.1:1"}});
    rs->save_device_id("dev-100");
    auto http = std::make_shared<MockHttpTransportForDelivery>();
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, std::make_shared<pux::api::ApiClient>(http), std::make_shared<MockNotificationService>());
    secrets->locked = true;
    ASSERT_THROWS(service->start(), pux::storage::KeyringLockedException);
    ASSERT_TRUE(service->is_stopped());
    secrets->locked = false;
    service->start();
    ASSERT_FALSE(service->is_stopped());
    service->stop();
}

TEST(delivery_late_registration_success_retains_uncertainty_marker) {
    class FailThenSucceed final : public pux::api::HttpTransport {
    public:
        int attempts = 0;
        pux::api::HttpResponse request(
            const std::string& method,
            const std::string& url,
            const std::vector<std::string>&,
            const std::string&,
            long
        ) override {
            if (method == "POST" && url.find("/record/devices") != std::string::npos) {
                ++attempts;
                if (attempts == 1) {
                    throw pux::api::ApiException("timed out");
                }
                return {200, "{\"device_id\":\"late-device\"}"};
            }
            return {200, "[]"};
        }
    };
    pux::crypto::init();
    auto secrets = std::make_shared<pux::storage::MemorySecretStore>();
    auto backend = std::make_shared<pux::storage::MemorySecretStore>();
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    auto kp = pux::crypto::generate_key_pair();
    backend->write("record_id", "11111111-2222-3333-4444-555555555555");
    backend->write("private_key", kp.private_key);
    backend->write("public_key", kp.public_key);
    backend->write("inbox", "inbox@test");
    backend->write("server_url", "http://127.0.0.1:9");
    backend->write("desktop_device_id", "desktop-token");
    snapshot->replace(backend->read_all());
    auto record = std::make_shared<pux::storage::RecordStore>(snapshot);
    record->init();
    auto transport = std::make_shared<FailThenSucceed>();
    auto storage = std::make_shared<pux::storage::StorageCoordinator>(backend, snapshot);
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record,
        std::make_shared<pux::api::ApiClient>(transport),
        std::make_shared<MockNotificationService>(),
        pux::delivery::DeliveryTiming{},
        storage
    );
    service->start();
    auto registration_idle = [&] {
        return !service->registration_in_flight() && !service->registration_activity_active();
    };
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (std::chrono::steady_clock::now() < deadline) {
        while (g_main_context_iteration(nullptr, FALSE)) {}
        if (transport->attempts >= 1 &&
            backend->read(pux::storage::kUncertainRegistrationKey).has_value() &&
            service->registration_outcome_uncertain() &&
            registration_idle()) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    ASSERT_EQ(transport->attempts, 1);
    ASSERT_TRUE(backend->read(pux::storage::kUncertainRegistrationKey).has_value());
    ASSERT_TRUE(service->registration_outcome_uncertain());
    ASSERT_TRUE(registration_idle());

    service->register_device_async();
    deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (std::chrono::steady_clock::now() < deadline) {
        while (g_main_context_iteration(nullptr, FALSE)) {}
        if (transport->attempts >= 2 && registration_idle()) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    ASSERT_EQ(transport->attempts, 2);
    ASSERT_TRUE(backend->read(pux::storage::kUncertainRegistrationKey).has_value());
    service->stop();
}

TEST(delivery_retries_startup_registration_with_saved_device_id) {
    using namespace std::chrono_literals;
    class RetryTransport : public pux::api::HttpTransport {
    public:
        std::atomic<int> registrations{0};
        pux::api::HttpResponse request(const std::string& method, const std::string& url,
            const std::vector<std::string>&, const std::string&, long) override {
            if (method == "POST" && url.find("/record/devices") != std::string::npos) {
                return ++registrations == 1 ? pux::api::HttpResponse{503, "offline"} :
                    pux::api::HttpResponse{200, "{\"device_id\":\"recreated\"}"};
            }
            return {200, "{\"deliveries\":[]}"};
        }
    };
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();
    auto rs = std::make_shared<pux::storage::RecordStore>(std::make_shared<pux::storage::MemorySecretStore>());
    rs->save_enrollment({{"v",1},{"record_id","11111111-2222-3333-4444-555555555555"},
        {"private_key",kp.private_key},{"public_key",kp.public_key},{"inbox","inbox@pux.xyz"},{"server","http://127.0.0.1:1"}});
    rs->save_device_id("pruned-id");
    auto transport = std::make_shared<RetryTransport>();
    pux::delivery::DeliveryTiming timing{1s, 50ms, 200ms, 30ms};
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(rs, std::make_shared<pux::api::ApiClient>(transport), std::make_shared<MockNotificationService>(), timing);
    service->start();
    auto deadline = std::chrono::steady_clock::now() + 6s;
    while (std::chrono::steady_clock::now() < deadline && rs->device_id().value_or("") != "recreated") {
        while (g_main_context_iteration(nullptr, FALSE)) {}
        std::this_thread::sleep_for(2ms);
    }
    ASSERT_TRUE(transport->registrations.load() >= 2);
    ASSERT_EQ(rs->device_id().value(), "recreated");
    service->stop();
}

TEST(delivery_reconnect_backoff_matches_flutter_bounds) {
    const auto first = pux::delivery::reconnect_backoff_delay(0, 0);
    ASSERT_TRUE(first.count() >= 2000);
    ASSERT_TRUE(first.count() <= 300000);
    const auto rate_limited = pux::delivery::reconnect_backoff_delay(4, 0);
    ASSERT_TRUE(rate_limited.count() >= 32000);
}

namespace {

// Relay at its device cap: registration is refused with 422 too_many_devices
// until `at_limit` is cleared (a slot freed elsewhere).
class DeviceLimitTransport final : public pux::api::HttpTransport {
public:
    std::atomic<bool> at_limit{true};
    std::atomic<int> registrations{0};
    std::atomic<int> polls{0};

    pux::api::HttpResponse request(const std::string& method, const std::string& url,
        const std::vector<std::string>&, const std::string&, long) override {
        if (method == "POST" && url.find("/record/devices") != std::string::npos) {
            ++registrations;
            if (at_limit) return {422, "{\"error\":\"too_many_devices\"}"};
            return {200, "{\"device_id\":\"freed-slot-device\"}"};
        }
        if (method == "GET" && url.find("/record/deliveries") != std::string::npos) {
            ++polls;
            return {200, "{\"deliveries\":[]}"};
        }
        return {200, "{}"};
    }
};

std::shared_ptr<pux::storage::RecordStore> make_enrolled_store() {
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();
    auto rs = std::make_shared<pux::storage::RecordStore>(std::make_shared<pux::storage::MemorySecretStore>());
    // Port 1 refuses connections, so the websocket never reaches Ready and tests
    // observe only registration behaviour.
    rs->save_enrollment({{"v",1},{"record_id","11111111-2222-3333-4444-555555555555"},
        {"private_key",kp.private_key},{"public_key",kp.public_key},{"inbox","inbox@pux.xyz"},{"server","http://127.0.0.1:1"}});
    return rs;
}

template <class Pred>
bool pump_until(std::chrono::milliseconds limit, Pred done) {
    const auto deadline = std::chrono::steady_clock::now() + limit;
    while (std::chrono::steady_clock::now() < deadline) {
        while (g_main_context_iteration(nullptr, FALSE)) {}
        if (done()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    while (g_main_context_iteration(nullptr, FALSE)) {}
    return done();
}

pux::delivery::DeliveryTiming device_limit_timing(std::chrono::milliseconds retry, std::chrono::milliseconds retry_max) {
    using namespace std::chrono_literals;
    pux::delivery::DeliveryTiming timing{1h, 1h, 1h, 1h};
    timing.registration_retry = retry;
    timing.registration_retry_max = retry_max;
    return timing;
}

} // namespace

TEST(delivery_registration_retries_after_device_limit_and_recovers_when_slot_freed) {
    using namespace std::chrono_literals;
    auto rs = make_enrolled_store();
    auto transport = std::make_shared<DeviceLimitTransport>();
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        rs, std::make_shared<pux::api::ApiClient>(transport), std::make_shared<MockNotificationService>(),
        device_limit_timing(15ms, 40ms));
    std::vector<pux::delivery::DeliveryState> states;
    service->set_status_callback([&](const pux::delivery::DeliveryStatus& status) { states.push_back(status.state); });
    service->start();

    // Rejected, and the service keeps retrying by itself while the relay is full.
    ASSERT_TRUE(pump_until(3s, [&] { return transport->registrations.load() >= 3; }));
    ASSERT_TRUE(service->status().state == pux::delivery::DeliveryState::TooManyDevices);
    ASSERT_FALSE(service->is_stopped());
    ASSERT_FALSE(rs->device_id().has_value());
    // No flicker: background retries leave the visible state alone instead of
    // cycling the banner through Connecting.
    for (size_t i = 1; i < states.size(); ++i) {
        ASSERT_TRUE(states[i] == pux::delivery::DeliveryState::TooManyDevices);
    }

    // A slot is freed elsewhere. No restart and no user action.
    transport->at_limit = false;
    ASSERT_TRUE(pump_until(3s, [&] { return rs->device_id().value_or("") == "freed-slot-device"; }));
    // The device-limit error is withdrawn as soon as registration succeeds, not
    // only once the socket connects (it never does against port 1 here).
    ASSERT_TRUE(pump_until(3s, [&] { return service->status().state != pux::delivery::DeliveryState::TooManyDevices; }));
    ASSERT_TRUE(pump_until(3s, [&] { return transport->polls.load() >= 1; }));

    // Registration succeeded, so the retry cycle ends.
    ASSERT_TRUE(pump_until(1s, [&] { return service->registration_retry_timer_id() == 0; }));
    const int settled = transport->registrations.load();
    pump_until(150ms, [] { return false; });
    ASSERT_EQ(transport->registrations.load(), settled);
    service->set_status_callback(nullptr);
    service->stop();
}

TEST(delivery_manual_retry_after_device_limit_registers_without_waiting) {
    using namespace std::chrono_literals;
    auto rs = make_enrolled_store();
    auto transport = std::make_shared<DeviceLimitTransport>();
    // The automatic retry is an hour away, so only retry_registration() can act.
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        rs, std::make_shared<pux::api::ApiClient>(transport), std::make_shared<MockNotificationService>(),
        device_limit_timing(1h, 1h));

    // Not running yet.
    ASSERT_FALSE(service->retry_registration());

    service->start();
    // Still connecting, not rejected.
    ASSERT_FALSE(service->retry_registration());
    ASSERT_TRUE(pump_until(3s, [&] { return service->status().state == pux::delivery::DeliveryState::TooManyDevices; }));
    ASSERT_EQ(transport->registrations.load(), 1);

    // Still full: retry registers once more and the limit is shown again.
    ASSERT_TRUE(service->retry_registration());
    ASSERT_FALSE(service->retry_registration());  // already in flight
    ASSERT_TRUE(pump_until(3s, [&] {
        return transport->registrations.load() == 2 &&
               service->status().state == pux::delivery::DeliveryState::TooManyDevices; }));

    // Freed: retry registers and leaves the limit state.
    transport->at_limit = false;
    ASSERT_TRUE(service->retry_registration());
    ASSERT_TRUE(pump_until(3s, [&] { return rs->device_id().value_or("") == "freed-slot-device"; }));
    ASSERT_EQ(transport->registrations.load(), 3);
    ASSERT_TRUE(service->status().state != pux::delivery::DeliveryState::TooManyDevices);
    // Nothing left to retry.
    ASSERT_FALSE(service->retry_registration());
    service->stop();
}

TEST(delivery_device_limit_retry_stops_with_suspend_and_removal) {
    using namespace std::chrono_literals;
    auto rs = make_enrolled_store();
    auto transport = std::make_shared<DeviceLimitTransport>();
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        rs, std::make_shared<pux::api::ApiClient>(transport), std::make_shared<MockNotificationService>(),
        device_limit_timing(10ms, 20ms));
    service->start();
    ASSERT_TRUE(pump_until(3s, [&] { return transport->registrations.load() >= 2; }));

    // Removal (or a keyring failure) suspends the service: no timer may register
    // a device behind its back, and the manual action must refuse too.
    service->suspend();
    ASSERT_EQ(service->registration_retry_timer_id(), 0u);
    ASSERT_FALSE(service->retry_registration());
    pump_until(100ms, [] { return false; });  // let any in-flight attempt drain
    const int frozen = transport->registrations.load();
    transport->at_limit = false;
    pump_until(250ms, [] { return false; });  // many retry intervals
    ASSERT_EQ(transport->registrations.load(), frozen);
    ASSERT_FALSE(rs->device_id().has_value());

    // A fresh start is a clean slate: the rejection is tried again.
    transport->at_limit = true;
    service->start();
    ASSERT_TRUE(pump_until(3s, [&] { return transport->registrations.load() > frozen; }));
    service->stop();
    ASSERT_EQ(service->registration_retry_timer_id(), 0u);
}

TEST(delivery_registration_retry_delay_doubles_to_a_cap) {
    using namespace std::chrono_literals;
    ASSERT_EQ(pux::delivery::registration_retry_delay(0, 30s, 10min).count(), 30000);
    ASSERT_EQ(pux::delivery::registration_retry_delay(1, 30s, 10min).count(), 60000);
    ASSERT_EQ(pux::delivery::registration_retry_delay(2, 30s, 10min).count(), 120000);
    ASSERT_EQ(pux::delivery::registration_retry_delay(4, 30s, 10min).count(), 480000);
    ASSERT_EQ(pux::delivery::registration_retry_delay(5, 30s, 10min).count(), 600000);
    ASSERT_EQ(pux::delivery::registration_retry_delay(1000, 30s, 10min).count(), 600000);
    ASSERT_EQ(pux::delivery::registration_retry_delay(-3, 30s, 10min).count(), 30000);
    // A cap below the base never shortens the first delay; a zero base is not a busy loop.
    ASSERT_EQ(pux::delivery::registration_retry_delay(3, 30s, 1s).count(), 30000);
    ASSERT_TRUE(pux::delivery::registration_retry_delay(0, 0ms, 10min).count() >= 1);
}
