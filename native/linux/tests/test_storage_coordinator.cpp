#include "test_harness.hpp"
#include "../src/storage/storage_coordinator.hpp"
#include "../src/storage/registration_outcome.hpp"
#include "../src/delivery/desktop_delivery_service.hpp"
#include <glib.h>
#include <gio/gio.h>
#include <atomic>
#include <chrono>
#include <thread>

namespace {
class SlowStorage : public pux::storage::MemorySecretStore {
public:
    std::atomic<bool> entered{false};
    std::atomic<bool> release{false};
    std::optional<std::string> read(const std::string& key) override {
        if (!entered.exchange(true)) {
            while (!release.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return MemorySecretStore::read(key);
    }
};
void spin_until(const std::function<bool()>& condition) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (!condition() && std::chrono::steady_clock::now() < deadline) {
        while (g_main_context_iteration(nullptr, FALSE)) {}
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
}
}

TEST(storage_worker_keeps_main_loop_responsive_and_discards_stale_result) {
    using namespace std::chrono_literals;
    auto backend = std::make_shared<SlowStorage>();
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    auto coordinator = std::make_shared<pux::storage::StorageCoordinator>(backend, snapshot);
    auto old = std::make_shared<std::atomic<bool>>(true);
    auto current = std::make_shared<std::atomic<bool>>(true);
    bool old_callback = false, new_callback = false;
    auto start = std::chrono::steady_clock::now();
    coordinator->submit([](pux::storage::RecordStore& store) { store.secret_store()->write("marker", "old"); }, old,
        [&](const std::string&) { old_callback = true; });
    ASSERT_TRUE(std::chrono::steady_clock::now() - start < 100ms);
    spin_until([&] { return backend->entered.load(); });
    ASSERT_TRUE(backend->entered.load());
    bool heartbeat = false;
    auto timer = g_timeout_add(10, +[](gpointer p) -> gboolean { *static_cast<bool*>(p) = true; return G_SOURCE_REMOVE; }, &heartbeat);
    spin_until([&] { return heartbeat; });
    if (!heartbeat) g_source_remove(timer);
    ASSERT_TRUE(heartbeat);
    ASSERT_FALSE(snapshot->read("marker").has_value());
    *old = false;
    coordinator->submit([](pux::storage::RecordStore& store) { store.secret_store()->write("marker", "new"); }, current,
        [&](const std::string& error) { new_callback = error.empty(); });
    backend->release = true;
    spin_until([&] { return new_callback; });
    ASSERT_TRUE(new_callback);
    ASSERT_FALSE(old_callback);
    ASSERT_EQ(snapshot->read("marker").value_or(""), "new");
}

#include "../src/crypto/crypto.hpp"
TEST(storage_worker_serializes_enrollment_device_and_removal) {
    auto backend = std::make_shared<pux::storage::MemorySecretStore>();
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::StorageCoordinator coordinator(backend, snapshot);
    auto generation = std::make_shared<std::atomic<bool>>(true);
    pux::crypto::init();
    auto key = pux::crypto::generate_key_pair();
    nlohmann::json payload = {{"v",1}, {"record_id","11111111-2222-3333-4444-555555555555"},
        {"private_key",key.private_key},{"public_key",key.public_key},{"inbox","x@example.com"},{"server","http://127.0.0.1:1"}};
    bool enrolled = false;
    coordinator.submit([payload](pux::storage::RecordStore& store) { store.save_enrollment(payload); store.desktop_device_id(); }, generation,
        [&](const std::string& error) { enrolled = error.empty(); });
    ASSERT_FALSE(snapshot->read("record_id").has_value());
    spin_until([&] { return enrolled; });
    ASSERT_TRUE(enrolled);
    ASSERT_EQ(snapshot->read("record_id").value_or(""), "11111111-2222-3333-4444-555555555555");
    ASSERT_TRUE(snapshot->read("desktop_device_id").has_value());
    bool device_written = false, removed = false;
    coordinator.submit([](pux::storage::RecordStore& store) { store.save_device_id("device-1"); }, generation,
        [&](const std::string& error) { device_written = error.empty(); });
    coordinator.submit([](pux::storage::RecordStore& store) { store.clear(); }, generation,
        [&](const std::string& error) { removed = error.empty(); });
    spin_until([&] { return removed; });
    ASSERT_TRUE(device_written); ASSERT_TRUE(removed);
    ASSERT_FALSE(snapshot->read("record_id").has_value());
    ASSERT_FALSE(snapshot->read("device_id").has_value());
    ASSERT_FALSE(backend->read("record_id").has_value());
    ASSERT_FALSE(backend->read("device_id").has_value());
}

TEST(storage_failure_does_not_publish_partial_enrollment) {
    class FailingStore : public pux::storage::MemorySecretStore {
    public:
        void replace_all(std::map<std::string, std::string> data) override {
            if (data.count("private_key") > 0) {
                throw pux::storage::StorageException("locked");
            }
            MemorySecretStore::replace_all(std::move(data));
        }
    };
    auto backend = std::make_shared<FailingStore>();
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::StorageCoordinator coordinator(backend, snapshot);
    auto generation = std::make_shared<std::atomic<bool>>(true);
    auto key = pux::crypto::generate_key_pair();
    nlohmann::json payload = {{"v",1}, {"record_id","11111111-2222-3333-4444-555555555555"},
        {"private_key",key.private_key},{"public_key",key.public_key},{"inbox","x@example.com"},{"server","http://127.0.0.1:1"}};
    bool finished = false; std::string error;
    coordinator.submit([payload](pux::storage::RecordStore& store) { store.save_enrollment(payload); }, generation,
        [&](const std::string& failure) { error = failure; finished = true; });
    spin_until([&] { return finished; });
    ASSERT_TRUE(finished); ASSERT_EQ(error, "locked");
    ASSERT_FALSE(snapshot->read("record_id").has_value());
    ASSERT_FALSE(backend->read("record_id").has_value());
    ASSERT_FALSE(backend->read("public_key").has_value());
}

#include "../src/storage/removal_intent.hpp"
#include "../src/storage/registration_outcome.hpp"
#include "../src/ui/removal_controller.hpp"
namespace {
class GatedRemovalTransport : public pux::api::HttpTransport {
public:
    std::atomic<int> calls{0};
    std::atomic<int> registrations{0};
    std::atomic<bool> entered{false};
    std::atomic<bool> release{true};
    std::atomic<bool> fail_once{false};
    std::string last_delete_url;
    pux::api::HttpResponse request(const std::string& method, const std::string& url, const std::vector<std::string>&,
                                  const std::string&, long) override {
        if (method == "POST") { ++registrations; return {200, "{\"device_id\":\"device-1\"}"}; }
        if (method != "DELETE") return {400, "unexpected"};
        last_delete_url = url;
        ++calls; entered = true;
        while (!release.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (fail_once.exchange(false)) return {503, "offline"};
        return {204, ""};
    }
};
class GatedClearStore : public pux::storage::MemorySecretStore {
public:
    std::atomic<bool> entered{false};
    std::atomic<bool> release{true};
    std::atomic<bool> fail_once{false};
    void replace_all(std::map<std::string, std::string> data) override {
        entered = true;
        while (!release.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        if (fail_once.exchange(false)) {
            throw pux::storage::StorageException("keyring locked");
        }
        MemorySecretStore::replace_all(std::move(data));
    }
    void clear() override { replace_all({}); }
};
void seed_relay(pux::storage::MemorySecretStore& backend) {
    backend.write("record_id", "11111111-2222-3333-4444-555555555555");
    backend.write("private_key", "private");
    backend.write("public_key", "public");
    backend.write("server_url", "http://127.0.0.1:1");
    backend.write("device_id", "device-1");
    backend.write("desktop_device_id", "desktop-token");
}
}

TEST(durable_removal_survives_window_close_during_delete_and_clear) {
    for (bool block_delete : {true, false}) {
        auto backend = std::make_shared<GatedClearStore>();
        seed_relay(*backend);
        auto transport = std::make_shared<GatedRemovalTransport>();
        transport->release = !block_delete;
        backend->release = block_delete;
        auto api = std::make_shared<pux::api::ApiClient>(transport);
        auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
        pux::storage::StorageCoordinator coordinator(backend, snapshot);
        auto window_alive = std::make_shared<std::atomic<bool>>(true);
        bool finished = false, ui_called = false; std::string error;
        coordinator.submit_durable([api](pux::storage::RecordStore& store) {
            pux::storage::complete_removal(store, *api, {"device", "11111111-2222-3333-4444-555555555555", "device-1"}, true);
        }, [&](const std::string& result) { error = result; finished = true; if (window_alive->load()) ui_called = true; });
        spin_until([&] { return block_delete ? transport->entered.load() : backend->entered.load(); });
        bool reached = block_delete ? transport->entered.load() : backend->entered.load();
        auto marker = backend->read(pux::storage::kRemovalIntentKey);
        *window_alive = false;
        transport->release = true; backend->release = true;
        spin_until([&] { return finished; });
        ASSERT_TRUE(reached); ASSERT_TRUE(marker.has_value()); ASSERT_TRUE(finished); ASSERT_TRUE(error.empty());
        ASSERT_FALSE(ui_called);
        ASSERT_FALSE(backend->read("record_id").has_value());
        ASSERT_FALSE(backend->read(pux::storage::kRemovalIntentKey).has_value());
    }
}

TEST(removal_clear_failure_recovers_on_restart_before_registration) {
    auto backend = std::make_shared<GatedClearStore>(); seed_relay(*backend); backend->fail_once = true;
    auto transport = std::make_shared<GatedRemovalTransport>();
    auto api = std::make_shared<pux::api::ApiClient>(transport);
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    bool first_finished = false; std::string first_error;
    {
        pux::storage::StorageCoordinator coordinator(backend, snapshot);
        coordinator.submit_durable([api](pux::storage::RecordStore& store) {
            pux::storage::complete_removal(store, *api, {"relay", "11111111-2222-3333-4444-555555555555", ""}, true);
        }, [&](const std::string& error) { first_error = error; first_finished = true; });
        spin_until([&] { return first_finished; });
        ASSERT_TRUE(first_finished); ASSERT_EQ(first_error, "keyring locked");
        ASSERT_TRUE(backend->read(pux::storage::kRemovalIntentKey).has_value());
        ASSERT_TRUE(backend->read("record_id").has_value());
    }
    auto restarted_snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    bool recovered = false; std::string recovery_error;
    pux::storage::StorageCoordinator restarted(backend, restarted_snapshot);
    restarted.submit_durable([api](pux::storage::RecordStore& store) { pux::storage::recover_removal(store, *api); },
        [&](const std::string& error) { recovery_error = error; recovered = true; });
    spin_until([&] { return recovered; });
    ASSERT_TRUE(recovered); ASSERT_TRUE(recovery_error.empty()); ASSERT_EQ(transport->calls.load(), 2);
    ASSERT_FALSE(restarted_snapshot->read("record_id").has_value());
    ASSERT_FALSE(backend->read(pux::storage::kRemovalIntentKey).has_value());
}

TEST(removal_device_fences_uncertain_registration_during_inflight_post) {
    class BlockedRegistrationTransport final : public GatedRemovalTransport {
    public:
        std::atomic<bool> registration_blocked{true};
        std::atomic<bool> registration_entered{false};
        pux::api::HttpResponse request(
            const std::string& method,
            const std::string& url,
            const std::vector<std::string>& headers,
            const std::string& body,
            long timeout
        ) override {
            if (method == "POST" && url.find("/record/devices") != std::string::npos) {
                registration_entered = true;
                while (registration_blocked.load()) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                return {200, "{\"device_id\":\"device-1\"}"};
            }
            return GatedRemovalTransport::request(method, url, headers, body, timeout);
        }
    };

    auto backend = std::make_shared<GatedClearStore>();
    seed_relay(*backend);
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    snapshot->replace(backend->read_all());
    auto record = std::make_shared<pux::storage::RecordStore>(snapshot);
    record->init();
    auto transport = std::make_shared<BlockedRegistrationTransport>();
    auto api = std::make_shared<pux::api::ApiClient>(transport);
    auto storage = std::make_shared<pux::storage::StorageCoordinator>(backend, snapshot);
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record,
        api,
        std::make_shared<pux::notifications::NotificationService>(),
        pux::delivery::DeliveryTiming{},
        storage
    );
    bool held = false;
    auto controller = std::make_shared<pux::ui::RemovalController>(
        storage, api, service, [&](bool v) { held = v; });

    service->start();
    spin_until([&] { return transport->registration_entered.load(); });
    controller->begin("device", "11111111-2222-3333-4444-555555555555", "device-1");
    spin_until([&] {
        return backend->read(pux::storage::kUncertainRegistrationKey).has_value() &&
               service->registration_outcome_uncertain();
    });

    ASSERT_TRUE(backend->read(pux::storage::kUncertainRegistrationKey).has_value());
    ASSERT_TRUE(service->registration_outcome_uncertain());

    transport->registration_blocked = false;
    spin_until([&] { return controller->state().phase == pux::ui::RemovalController::Phase::Idle; });
    ASSERT_FALSE(backend->read("record_id").has_value());
    ASSERT_TRUE(backend->read(pux::storage::kUncertainRegistrationKey).has_value());
    ASSERT_TRUE(backend->read(pux::storage::kRemovalRegistrationNoticeKey).has_value());
    ASSERT_FALSE(controller->state().post_success_notice.empty());
    controller->clear_post_success_notice();
    spin_until([&] {
        return !backend->read(pux::storage::kUncertainRegistrationKey).has_value() &&
               !backend->read(pux::storage::kRemovalRegistrationNoticeKey).has_value() &&
               controller->state().post_success_notice.empty();
    });
    ASSERT_FALSE(backend->read(pux::storage::kUncertainRegistrationKey).has_value());
    ASSERT_FALSE(backend->read(pux::storage::kRemovalRegistrationNoticeKey).has_value());
}

TEST(removal_device_delete_uses_known_id_without_registering) {
    auto backend = std::make_shared<GatedClearStore>();
    seed_relay(*backend);
    auto transport = std::make_shared<GatedRemovalTransport>();
    auto api = std::make_shared<pux::api::ApiClient>(transport);
    pux::storage::RecordStore store(backend);
    store.init();
    pux::storage::complete_removal(store, *api, {"device", "11111111-2222-3333-4444-555555555555", "stale-marker"}, false);
    ASSERT_EQ(transport->registrations.load(), 0);
    ASSERT_EQ(transport->calls.load(), 1);
    ASSERT_TRUE(transport->last_delete_url.find("/devices/device-1") != std::string::npos);
    ASSERT_FALSE(backend->read("record_id").has_value());
}

TEST(removal_intent_survives_restart_before_delete) {
    auto backend = std::make_shared<GatedClearStore>(); seed_relay(*backend);
    pux::storage::RecordStore initial(backend); initial.init();
    pux::storage::persist_removal_intent(initial, {"device", "11111111-2222-3333-4444-555555555555", "stale-device"});
    auto transport = std::make_shared<GatedRemovalTransport>();
    auto api = std::make_shared<pux::api::ApiClient>(transport);
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::StorageCoordinator restarted(backend, snapshot);
    bool finished = false; std::string failure;
    restarted.submit_durable([api](pux::storage::RecordStore& store) { pux::storage::recover_removal(store, *api); },
        [&](const std::string& error) { failure = error; finished = true; });
    ASSERT_FALSE(snapshot->read("record_id").has_value());
    spin_until([&] { return finished; });
    ASSERT_TRUE(finished); ASSERT_TRUE(failure.empty()); ASSERT_EQ(transport->calls.load(), 1);
    ASSERT_TRUE(transport->last_delete_url.find("/devices/device-1") != std::string::npos);
    ASSERT_FALSE(snapshot->read("record_id").has_value());
    ASSERT_FALSE(backend->read(pux::storage::kRemovalIntentKey).has_value());
}

TEST(removal_remote_failure_keeps_intent_for_restart_retry) {
    auto backend = std::make_shared<GatedClearStore>(); seed_relay(*backend);
    auto transport = std::make_shared<GatedRemovalTransport>(); transport->fail_once = true;
    auto api = std::make_shared<pux::api::ApiClient>(transport);
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    bool failed = false;
    {
        pux::storage::StorageCoordinator coordinator(backend, snapshot);
        coordinator.submit_durable([api](pux::storage::RecordStore& store) {
            pux::storage::complete_removal(store, *api, {"relay", "11111111-2222-3333-4444-555555555555", ""}, true);
        }, [&](const std::string& error) { failed = !error.empty(); });
        spin_until([&] { return failed; });
        ASSERT_TRUE(failed);
        ASSERT_TRUE(backend->read(pux::storage::kRemovalIntentKey).has_value());
    }
    auto new_snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::StorageCoordinator restarted(backend, new_snapshot);
    bool recovered = false;
    restarted.submit_durable([api](pux::storage::RecordStore& store) { pux::storage::recover_removal(store, *api); },
        [&](const std::string& error) { recovered = error.empty(); });
    spin_until([&] { return recovered; });
    ASSERT_TRUE(recovered); ASSERT_EQ(transport->calls.load(), 2);
    ASSERT_FALSE(backend->read("record_id").has_value());
}

TEST(removal_recovery_rejects_changed_server_without_remote_call) {
    auto backend = std::make_shared<GatedClearStore>(); seed_relay(*backend);
    pux::storage::RecordStore store(backend); store.init();
    pux::storage::persist_removal_intent(store, {"relay", "11111111-2222-3333-4444-555555555555", ""});
    backend->write("server_url", "https://other.example"); store.init();
    auto transport = std::make_shared<GatedRemovalTransport>();
    pux::api::ApiClient api(transport);
    ASSERT_THROWS(pux::storage::recover_removal(store, api), pux::storage::StorageException);
    ASSERT_EQ(transport->calls.load(), 0);
    ASSERT_TRUE(backend->read("record_id").has_value());
    ASSERT_TRUE(backend->read(pux::storage::kRemovalIntentKey).has_value());
}

#include "../src/ui/activation_gate.hpp"
TEST(application_activation_reuses_or_recreates_window_without_bypassing_guards) {
    struct Window { bool live = true; };
    struct Context {
        std::unique_ptr<Window> window;
        pux::ui::DeliveryStartState state{true, true, false, false, false, true, true};
        int created = 0;
        int started = 0;
        pux::delivery::DesktopDeliveryService* service = nullptr;
    } context;
    auto secrets = std::make_shared<pux::storage::MemorySecretStore>(); seed_relay(*secrets);
    secrets->write("server_url", "http://127.0.0.1:1");
    auto record = std::make_shared<pux::storage::RecordStore>(secrets); record->init();
    auto transport = std::make_shared<GatedRemovalTransport>();
    auto delivery_service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record, std::make_shared<pux::api::ApiClient>(transport),
        std::make_shared<pux::notifications::NotificationService>());
    context.service = delivery_service.get();
    auto slow_backend = std::make_shared<SlowStorage>();
    auto loading_snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::StorageCoordinator coordinator(slow_backend, loading_snapshot);
    auto loading_generation = std::make_shared<std::atomic<bool>>(true);
    coordinator.submit([](pux::storage::RecordStore&) {}, loading_generation,
        [&](const std::string& failure) { context.state.storage_error = !failure.empty(); context.state.storage_loading = false; });
    spin_until([&] { return slow_backend->entered.load(); });
    ASSERT_TRUE(slow_backend->entered.load());
    GApplication* application = g_application_new("xyz.vidur.pux.activation-test", G_APPLICATION_NON_UNIQUE);
    GError* error = nullptr;
    ASSERT_TRUE(g_application_register(application, nullptr, &error));
    g_signal_connect(application, "activate", G_CALLBACK(+[](GApplication*, gpointer data) {
        auto* c = static_cast<Context*>(data);
        if (pux::ui::ensure_live_window(c->window, [](const Window& w) { return w.live; }, [c] {
            ++c->created; c->state.storage_loading = true; return std::make_unique<Window>();
        })) c->state.window_alive = true;
        pux::ui::start_delivery_if_ready(c->state, [c] { ++c->started; c->state.stopped = false; c->service->start(); });
    }), &context);
    g_application_activate(application);
    g_application_activate(application);
    ASSERT_EQ(context.created, 1); ASSERT_EQ(context.started, 0);
    ASSERT_EQ(transport->registrations.load(), 0);
    slow_backend->release = true;
    spin_until([&] { return !context.state.storage_loading; });
    ASSERT_FALSE(context.state.storage_loading);
    context.state.storage_error = true;
    g_application_activate(application); ASSERT_EQ(context.started, 0);
    context.state.storage_error = false;
    context.state.removal_in_progress = true;
    g_application_activate(application); ASSERT_EQ(context.started, 0);
    context.window->live = false;
    g_application_activate(application);
    ASSERT_EQ(context.created, 2); ASSERT_EQ(context.started, 0);
    context.state.removal_in_progress = false;
    context.state.recovery_pending = true;
    context.state.storage_loading = false;
    g_application_activate(application); ASSERT_EQ(context.started, 0);
    ASSERT_EQ(transport->registrations.load(), 0);
    context.state.recovery_pending = false;
    g_application_activate(application); ASSERT_EQ(context.started, 1);
    g_application_activate(application); ASSERT_EQ(context.started, 1);
    spin_until([&] { return transport->registrations.load() == 1; });
    ASSERT_EQ(transport->registrations.load(), 1);
    delivery_service->stop();
    g_object_unref(application);
}

TEST(pending_offline_removal_can_be_forgotten_locally_without_claiming_server_success) {
    auto backend = std::make_shared<GatedClearStore>(); seed_relay(*backend);
    pux::storage::RecordStore store(backend); store.init();
    pux::storage::persist_removal_intent(store, {"relay", "11111111-2222-3333-4444-555555555555", ""});
    auto transport = std::make_shared<GatedRemovalTransport>(); transport->fail_once = true;
    pux::api::ApiClient api(transport);
    ASSERT_THROWS(pux::storage::recover_removal(store, api), pux::api::ApiException);
    ASSERT_TRUE(backend->read(pux::storage::kRemovalIntentKey).has_value());
    ASSERT_TRUE(backend->read("record_id").has_value());
    backend->fail_once = true;
    ASSERT_THROWS(pux::storage::forget_pending_locally(store), pux::storage::StorageException);
    ASSERT_TRUE(backend->read("record_id").has_value());
    auto marker = nlohmann::json::parse(backend->read(pux::storage::kRemovalIntentKey).value());
    ASSERT_EQ(marker.at("action").get<std::string>(), "local");
    auto calls_before = transport->calls.load();
    pux::storage::recover_removal(store, api);
    ASSERT_EQ(transport->calls.load(), calls_before);
    ASSERT_FALSE(backend->read("record_id").has_value());
    ASSERT_FALSE(backend->read(pux::storage::kRemovalIntentKey).has_value());
}

TEST(activation_during_gated_remote_removal_does_not_register_or_revive_enrollment) {
    struct Window { bool live = true; };
    struct State {
        std::unique_ptr<Window> window;
        pux::ui::DeliveryStartState gate{true, false, false, true, false, true, true};
        pux::delivery::DesktopDeliveryService* service = nullptr;
        int created = 0;
    } state;
    auto backend = std::make_shared<GatedClearStore>(); seed_relay(*backend);
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>(); snapshot->replace(backend->read_all());
    auto record = std::make_shared<pux::storage::RecordStore>(snapshot); record->init();
    auto transport = std::make_shared<GatedRemovalTransport>(); transport->release = false;
    auto api = std::make_shared<pux::api::ApiClient>(transport);
    auto delivery_service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record, api, std::make_shared<pux::notifications::NotificationService>());
    state.service = delivery_service.get();
    pux::storage::StorageCoordinator coordinator(backend, snapshot);
    bool finished = false;
    coordinator.submit_durable([api](pux::storage::RecordStore& store) {
        pux::storage::complete_removal(store, *api, {"relay", "11111111-2222-3333-4444-555555555555", ""}, true);
    }, [&](const std::string& error) {
        finished = error.empty(); state.gate.enrolled = record->is_enrolled();
        state.gate.removal_in_progress = false; state.gate.storage_loading = false;
    });
    spin_until([&] { return transport->entered.load(); });
    bool delete_started = transport->entered.load();
    GApplication* app = g_application_new("xyz.vidur.pux.removal-test", G_APPLICATION_NON_UNIQUE);
    GError* error = nullptr;
    bool registered = g_application_register(app, nullptr, &error);
    g_signal_connect(app, "activate", G_CALLBACK(+[](GApplication*, gpointer data) {
        auto* state = static_cast<State*>(data);
        pux::ui::ensure_live_window(state->window, [](const Window& w) { return w.live; }, [state] {
            ++state->created; state->gate.storage_loading = true; return std::make_unique<Window>();
        });
        pux::ui::start_delivery_if_ready(state->gate, [state] { state->service->start(); });
    }), &state);
    g_application_activate(app);
    state.window->live = false;
    g_application_activate(app);
    bool recreated = state.created == 2;
    bool no_registration_during_delete = transport->registrations.load() == 0;
    transport->release = true;
    spin_until([&] { return finished; });
    g_application_activate(app);
    bool no_registration_after = transport->registrations.load() == 0;
    delivery_service->stop(); g_object_unref(app);
    ASSERT_TRUE(registered); ASSERT_TRUE(delete_started); ASSERT_TRUE(recreated);
    ASSERT_TRUE(no_registration_during_delete); ASSERT_TRUE(finished); ASSERT_TRUE(no_registration_after);
    ASSERT_FALSE(snapshot->read("record_id").has_value());
}

#include "../src/ui/removal_controller.hpp"
namespace {
class FailInitialMarkerStore : public GatedClearStore {
public:
    std::atomic<bool> fail_marker{true};
    std::atomic<bool> marker_entered{false};
    std::atomic<bool> marker_release{true};
    std::atomic<bool> fail_marker_delete{false};
    std::atomic<bool> fail_after_clear{false};
    std::atomic<bool> fail_next_read_all{false};
    bool commit_then_fail = false;
    void write(const std::string& key, const std::string& value) override {
        if (key == pux::storage::kRemovalIntentKey && fail_marker.exchange(false)) {
            marker_entered = true;
            while (!marker_release.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
            if (commit_then_fail) GatedClearStore::write(key, value);
            throw pux::storage::StorageException("marker write failed");
        }
        GatedClearStore::write(key, value);
    }
    void delete_key(const std::string& key) override {
        if (key == pux::storage::kRemovalIntentKey && fail_marker_delete.exchange(false))
            throw pux::storage::StorageException("cannot verify cancellation");
        GatedClearStore::delete_key(key);
    }
    void replace_all(std::map<std::string, std::string> data) override {
        GatedClearStore::replace_all(std::move(data));
        if (fail_after_clear.exchange(false)) fail_next_read_all = true;
    }
    std::map<std::string, std::string> read_all() override {
        if (fail_next_read_all.exchange(false)) throw pux::storage::StorageException("snapshot unavailable");
        return GatedClearStore::read_all();
    }
};
struct RemovalFixture {
    bool held = false;
    static std::shared_ptr<FailInitialMarkerStore> make_backend() { auto b = std::make_shared<FailInitialMarkerStore>(); seed_relay(*b); return b; }
    std::shared_ptr<FailInitialMarkerStore> backend = make_backend();
    std::shared_ptr<pux::storage::MemorySecretStore> snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    std::shared_ptr<pux::storage::RecordStore> record = std::make_shared<pux::storage::RecordStore>(snapshot);
    std::shared_ptr<GatedRemovalTransport> transport = std::make_shared<GatedRemovalTransport>();
    std::shared_ptr<pux::api::ApiClient> api = std::make_shared<pux::api::ApiClient>(transport);
    std::shared_ptr<pux::notifications::NotificationService> notifications = std::make_shared<pux::notifications::NotificationService>();
    std::shared_ptr<pux::delivery::DesktopDeliveryService> service = std::make_shared<pux::delivery::DesktopDeliveryService>(record, api, notifications);
    std::shared_ptr<pux::storage::StorageCoordinator> storage = std::make_shared<pux::storage::StorageCoordinator>(backend, snapshot);
    std::shared_ptr<pux::ui::RemovalController> controller = std::make_shared<pux::ui::RemovalController>(storage, api, service, [this](bool value) { held = value; });
    RemovalFixture() { snapshot->replace(backend->read_all()); record->init(); }
    void begin() { controller->begin("relay", "11111111-2222-3333-4444-555555555555", "device-1"); }
};

class SlowFenceStore : public pux::storage::MemorySecretStore {
public:
    std::atomic<bool> entered{false};
    std::atomic<bool> release{false};
    void write(const std::string& key, const std::string& value) override {
        if (key == pux::storage::kUncertainRegistrationKey) {
            entered = true;
            while (!release.load()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
        pux::storage::MemorySecretStore::write(key, value);
    }
};
}

class MainThreadSnapshot : public pux::storage::MemorySecretStore {
public:
    std::atomic<bool> replaced{false};
    std::thread::id owner = std::this_thread::get_id();
    void replace(std::map<std::string, std::string> data) {
        replaced = std::this_thread::get_id() == owner;
        pux::storage::MemorySecretStore::replace(std::move(data));
    }
};

TEST(storage_snapshot_replace_runs_on_main_thread_only) {
    auto backend = std::make_shared<SlowFenceStore>();
    backend->write("record_id", "11111111-2222-3333-4444-555555555555");
    auto snapshot = std::make_shared<MainThreadSnapshot>();
    snapshot->replace(backend->read_all());
    pux::storage::StorageCoordinator coordinator(backend, snapshot);
    std::atomic<bool> finished{false};
    coordinator.submit_durable([](pux::storage::RecordStore& store) {
        pux::storage::mark_registration_outcome_uncertain(store);
    }, [&](const std::string&) { finished = true; });
    spin_until([&] { return backend->entered.load(); });
    ASSERT_FALSE(finished.load());
    backend->release = true;
    spin_until([&] { return finished.load(); });
    ASSERT_TRUE(snapshot->replaced.load());
    ASSERT_TRUE(snapshot->read(pux::storage::kUncertainRegistrationKey).has_value());
}

TEST(storage_async_fence_does_not_block_calling_thread) {
    auto backend = std::make_shared<SlowFenceStore>();
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    pux::storage::StorageCoordinator coordinator(backend, snapshot);
    std::atomic<bool> submit_returned{false};
    std::atomic<bool> worker_done{false};
    std::thread caller([&] {
        coordinator.submit_durable(
            [](pux::storage::RecordStore& store) { pux::storage::mark_registration_outcome_uncertain(store); },
            [&](const std::string&) { worker_done = true; });
        submit_returned = true;
    });
    spin_until([&] { return backend->entered.load(); });
    ASSERT_TRUE(submit_returned.load());
    ASSERT_FALSE(worker_done.load());
    backend->release = true;
    spin_until([&] { return worker_done.load(); });
    caller.join();
}

TEST(removal_device_hold_engaged_before_async_fence_completes) {
    class BlockedRegistrationTransport final : public GatedRemovalTransport {
    public:
        std::atomic<bool> registration_blocked{true};
        std::atomic<bool> registration_entered{false};
        pux::api::HttpResponse request(
            const std::string& method,
            const std::string& url,
            const std::vector<std::string>& headers,
            const std::string& body,
            long timeout
        ) override {
            if (method == "POST" && url.find("/record/devices") != std::string::npos) {
                registration_entered = true;
                while (registration_blocked.load()) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                return {200, "{\"device_id\":\"device-1\"}"};
            }
            return GatedRemovalTransport::request(method, url, headers, body, timeout);
        }
    };
    auto backend = std::make_shared<SlowFenceStore>();
    seed_relay(*backend);
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    snapshot->replace(backend->read_all());
    auto record = std::make_shared<pux::storage::RecordStore>(snapshot);
    record->init();
    auto transport = std::make_shared<BlockedRegistrationTransport>();
    auto api = std::make_shared<pux::api::ApiClient>(transport);
    auto storage = std::make_shared<pux::storage::StorageCoordinator>(backend, snapshot);
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record, api, std::make_shared<pux::notifications::NotificationService>(), pux::delivery::DeliveryTiming{}, storage);
    bool held = false;
    auto controller = std::make_shared<pux::ui::RemovalController>(storage, api, service, [&](bool v) { held = v; });
    service->start();
    spin_until([&] { return transport->registration_entered.load(); });
    controller->begin("device", "11111111-2222-3333-4444-555555555555", "device-1");
    spin_until([&] { return backend->entered.load(); });
    ASSERT_TRUE(held);
    ASSERT_FALSE(backend->read(pux::storage::kRemovalIntentKey).has_value());
    backend->release = true;
    transport->registration_blocked = false;
    transport->release = true;
    spin_until([&] { return controller->state().phase == pux::ui::RemovalController::Phase::Idle; });
}

class FenceFailStore : public GatedClearStore {
public:
    std::atomic<bool> fail_fence{true};
    void write(const std::string& key, const std::string& value) override {
        if (key == pux::storage::kUncertainRegistrationKey && fail_fence.exchange(false)) {
            throw pux::storage::StorageException("uncertainty fence failed");
        }
        GatedClearStore::write(key, value);
    }
};

TEST(removal_device_fence_failure_enters_unconfirmed_without_intent) {
    class BlockedRegistrationTransport final : public GatedRemovalTransport {
    public:
        std::atomic<bool> registration_blocked{true};
        std::atomic<bool> registration_entered{false};
        pux::api::HttpResponse request(
            const std::string& method,
            const std::string& url,
            const std::vector<std::string>& headers,
            const std::string& body,
            long timeout
        ) override {
            if (method == "POST" && url.find("/record/devices") != std::string::npos) {
                registration_entered = true;
                while (registration_blocked.load()) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                return {200, "{\"device_id\":\"device-1\"}"};
            }
            return GatedRemovalTransport::request(method, url, headers, body, timeout);
        }
    };
    auto backend = std::make_shared<FenceFailStore>();
    seed_relay(*backend);
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    snapshot->replace(backend->read_all());
    auto record = std::make_shared<pux::storage::RecordStore>(snapshot);
    record->init();
    auto transport = std::make_shared<BlockedRegistrationTransport>();
    auto api = std::make_shared<pux::api::ApiClient>(transport);
    auto storage = std::make_shared<pux::storage::StorageCoordinator>(backend, snapshot);
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record, api, std::make_shared<pux::notifications::NotificationService>(), pux::delivery::DeliveryTiming{}, storage);
    bool held = false;
    auto controller = std::make_shared<pux::ui::RemovalController>(storage, api, service, [&](bool v) { held = v; });
    service->start();
    spin_until([&] { return transport->registration_entered.load(); });
    controller->begin("device", "11111111-2222-3333-4444-555555555555", "device-1");
    spin_until([&] {
        return controller->state().phase == pux::ui::RemovalController::Phase::Unconfirmed;
    });
    ASSERT_TRUE(held);
    ASSERT_TRUE(controller->state().can_cancel);
    ASSERT_FALSE(backend->read(pux::storage::kRemovalIntentKey).has_value());
    ASSERT_EQ(transport->calls.load(), 0);
    transport->registration_blocked = false;
}

TEST(removal_device_fence_retry_reruns_fence_before_removal) {
    class BlockedRegistrationTransport final : public GatedRemovalTransport {
    public:
        std::atomic<bool> registration_blocked{true};
        std::atomic<bool> registration_entered{false};
        pux::api::HttpResponse request(
            const std::string& method,
            const std::string& url,
            const std::vector<std::string>& headers,
            const std::string& body,
            long timeout
        ) override {
            if (method == "POST" && url.find("/record/devices") != std::string::npos) {
                registration_entered = true;
                while (registration_blocked.load()) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                return {200, "{\"device_id\":\"device-1\"}"};
            }
            return GatedRemovalTransport::request(method, url, headers, body, timeout);
        }
    };
    auto backend = std::make_shared<FenceFailStore>();
    seed_relay(*backend);
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    snapshot->replace(backend->read_all());
    auto record = std::make_shared<pux::storage::RecordStore>(snapshot);
    record->init();
    auto transport = std::make_shared<BlockedRegistrationTransport>();
    auto api = std::make_shared<pux::api::ApiClient>(transport);
    auto storage = std::make_shared<pux::storage::StorageCoordinator>(backend, snapshot);
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record, api, std::make_shared<pux::notifications::NotificationService>(), pux::delivery::DeliveryTiming{}, storage);
    auto controller = std::make_shared<pux::ui::RemovalController>(storage, api, service, [](bool) {});
    service->start();
    spin_until([&] { return transport->registration_entered.load(); });
    controller->begin("device", "11111111-2222-3333-4444-555555555555", "device-1");
    spin_until([&] {
        return controller->state().phase == pux::ui::RemovalController::Phase::Unconfirmed;
    });
    controller->retry();
    transport->registration_blocked = false;
    transport->release = true;
    spin_until([&] { return controller->state().phase == pux::ui::RemovalController::Phase::Idle; });
    ASSERT_FALSE(backend->read("record_id").has_value());
    ASSERT_TRUE(backend->read(pux::storage::kRemovalRegistrationNoticeKey).has_value());
    ASSERT_FALSE(controller->state().post_success_notice.empty());
}

class FailNoticeClearStore : public GatedClearStore {
public:
    std::atomic<int> clear_attempts{0};
    void replace_all(std::map<std::string, std::string> data) override {
        const auto before = read_all();
        const bool clears_registration_warning =
            before.find(pux::storage::kRemovalRegistrationNoticeKey) != before.end() &&
            data.find(pux::storage::kRemovalRegistrationNoticeKey) == data.end();
        if (clears_registration_warning && clear_attempts.fetch_add(1) == 0) {
            throw pux::storage::StorageException("notice clear failed");
        }
        GatedClearStore::replace_all(std::move(data));
    }
};

TEST(removal_recovery_materializes_warning_from_intent_atomically) {
    auto backend = std::make_shared<GatedClearStore>();
    seed_relay(*backend);
    pux::storage::RemovalIntent intent{
        "device", "11111111-2222-3333-4444-555555555555", "device-1", true};
    pux::storage::RecordStore seeded(backend);
    seeded.init();
    pux::storage::persist_removal_intent(seeded, intent);
    ASSERT_FALSE(backend->read(pux::storage::kRemovalRegistrationNoticeKey).has_value());
    auto transport = std::make_shared<GatedRemovalTransport>();
    transport->release = true;
    pux::storage::RecordStore store(backend);
    store.init();
    pux::api::ApiClient api(transport);
    pux::storage::recover_removal(store, api);
    ASSERT_FALSE(backend->read("record_id").has_value());
    ASSERT_FALSE(backend->read(pux::storage::kRemovalIntentKey).has_value());
    ASSERT_TRUE(backend->read(pux::storage::kUncertainRegistrationKey).has_value());
    ASSERT_TRUE(backend->read(pux::storage::kRemovalRegistrationNoticeKey).has_value());
}

TEST(post_success_notice_persists_until_acknowledged) {
    auto backend = std::make_shared<GatedClearStore>();
    backend->write(pux::storage::kUncertainRegistrationKey, "1");
    backend->write(pux::storage::kRemovalRegistrationNoticeKey, pux::storage::removal_registration_notice_text());
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    snapshot->replace(backend->read_all());
    auto record = std::make_shared<pux::storage::RecordStore>(snapshot);
    record->init();
    auto storage = std::make_shared<pux::storage::StorageCoordinator>(backend, snapshot);
    auto controller = std::make_shared<pux::ui::RemovalController>(
        storage,
        std::make_shared<pux::api::ApiClient>(std::make_shared<GatedRemovalTransport>()),
        std::make_shared<pux::delivery::DesktopDeliveryService>(
            record,
            std::make_shared<pux::api::ApiClient>(std::make_shared<GatedRemovalTransport>()),
            std::make_shared<pux::notifications::NotificationService>()),
        [](bool) {});
    controller->restore_post_removal_notice_from_store(*record);
    ASSERT_FALSE(controller->state().post_success_notice.empty());
    ASSERT_TRUE(backend->read(pux::storage::kRemovalRegistrationNoticeKey).has_value());
}

TEST(post_success_notice_clear_after_ack_retries_failed_keyring_delete) {
    auto backend = std::make_shared<FailNoticeClearStore>();
    backend->write(pux::storage::kUncertainRegistrationKey, "1");
    backend->write(pux::storage::kRemovalRegistrationNoticeKey, pux::storage::removal_registration_notice_text());
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    snapshot->replace(backend->read_all());
    auto record = std::make_shared<pux::storage::RecordStore>(snapshot);
    record->init();
    auto storage = std::make_shared<pux::storage::StorageCoordinator>(backend, snapshot);
    auto controller = std::make_shared<pux::ui::RemovalController>(
        storage,
        std::make_shared<pux::api::ApiClient>(std::make_shared<GatedRemovalTransport>()),
        std::make_shared<pux::delivery::DesktopDeliveryService>(
            record,
            std::make_shared<pux::api::ApiClient>(std::make_shared<GatedRemovalTransport>()),
            std::make_shared<pux::notifications::NotificationService>()),
        [](bool) {});
    controller->restore_post_removal_notice_from_store(*record);
    std::atomic<bool> first_done{false};
    std::string first_error;
    controller->clear_post_success_notice([&](const std::string& error) {
        first_error = error;
        first_done = true;
    });
    spin_until([&] { return first_done.load(); });
    ASSERT_FALSE(first_error.empty());
    ASSERT_FALSE(controller->state().post_success_notice.empty());
    ASSERT_TRUE(backend->read(pux::storage::kRemovalRegistrationNoticeKey).has_value());
    std::atomic<bool> second_done{false};
    controller->clear_post_success_notice([&](const std::string& error) {
        ASSERT_TRUE(error.empty());
        second_done = true;
    });
    spin_until([&] { return second_done.load(); });
    ASSERT_TRUE(controller->state().post_success_notice.empty());
    ASSERT_FALSE(backend->read(pux::storage::kRemovalRegistrationNoticeKey).has_value());
    ASSERT_FALSE(backend->read(pux::storage::kUncertainRegistrationKey).has_value());
}

TEST(removal_registration_notice_restored_after_restart_until_cleared) {
    auto backend = std::make_shared<GatedClearStore>();
    seed_relay(*backend);
    backend->write(pux::storage::kUncertainRegistrationKey, "1");
    backend->write(pux::storage::kRemovalRegistrationNoticeKey, pux::storage::removal_registration_notice_text());
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    snapshot->replace(backend->read_all());
    auto record = std::make_shared<pux::storage::RecordStore>(snapshot);
    record->init();
    auto api = std::make_shared<pux::api::ApiClient>(std::make_shared<GatedRemovalTransport>());
    auto storage = std::make_shared<pux::storage::StorageCoordinator>(backend, snapshot);
    auto service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record, api, std::make_shared<pux::notifications::NotificationService>(), pux::delivery::DeliveryTiming{}, storage);
    auto controller = std::make_shared<pux::ui::RemovalController>(storage, api, service, [](bool) {});
    controller->restore_post_removal_notice_from_store(*record);
    ASSERT_FALSE(controller->state().post_success_notice.empty());
    controller->clear_post_success_notice();
    spin_until([&] {
        return !backend->read(pux::storage::kUncertainRegistrationKey).has_value() &&
               !backend->read(pux::storage::kRemovalRegistrationNoticeKey).has_value() &&
               controller->state().post_success_notice.empty();
    });
    ASSERT_TRUE(controller->state().post_success_notice.empty());
}

TEST(removal_begin_is_idempotent_while_another_removal_is_active) {
    using Phase = pux::ui::RemovalController::Phase;
    RemovalFixture fixture;
    fixture.begin();
    spin_until([&] { return fixture.controller->state().phase != Phase::Idle; });
    const auto phase_before = fixture.controller->state().phase;
    fixture.controller->begin("device", "11111111-2222-3333-4444-555555555555", "other-device");
    ASSERT_TRUE(fixture.controller->state().phase == phase_before);
    fixture.transport->release = true;
    spin_until([&] { return fixture.controller->state().phase == Phase::Idle; });
}

TEST(removal_controller_failed_intent_survives_close_and_retries_real_action) {
    using Phase = pux::ui::RemovalController::Phase;
    RemovalFixture fixture;
    fixture.backend->marker_release = false;
    int old_window_updates = 0, new_window_updates = 0;
    fixture.controller->set_observer([&] { ++old_window_updates; });
    fixture.begin();
    spin_until([&] { return fixture.backend->marker_entered.load(); });
    bool entered = fixture.backend->marker_entered.load();
    fixture.controller->set_observer(nullptr); // Window closes while keyring is blocked.
    int old_count = old_window_updates;
    fixture.backend->marker_release = true;
    spin_until([&] { return fixture.controller->state().phase == Phase::Unconfirmed; });
    ASSERT_TRUE(entered); ASSERT_TRUE(fixture.held);
    ASSERT_EQ(fixture.controller->state().action, "relay");
    ASSERT_TRUE(fixture.controller->state().can_cancel);
    ASSERT_EQ(fixture.transport->calls.load(), 0);
    ASSERT_FALSE(fixture.backend->read(pux::storage::kRemovalIntentKey).has_value());
    ASSERT_EQ(old_window_updates, old_count);
    struct Window { bool live = false; };
    struct Reopen { RemovalFixture* fixture; std::unique_ptr<Window> window; int created = 0; } reopened{&fixture};
    reopened.window = std::make_unique<Window>();
    auto* application = g_application_new("xyz.vidur.pux.intent-test", G_APPLICATION_NON_UNIQUE);
    GError* error = nullptr;
    ASSERT_TRUE(g_application_register(application, nullptr, &error));
    g_signal_connect(application, "activate", G_CALLBACK(+[](GApplication*, gpointer data) {
        auto* view = static_cast<Reopen*>(data);
        pux::ui::ensure_live_window(view->window, [](const Window& window) { return window.live; }, [view] {
            ++view->created; auto window = std::make_unique<Window>(); window->live = true; return window;
        });
        auto active = view->fixture->controller->state().phase != pux::ui::RemovalController::Phase::Idle;
        pux::ui::start_delivery_if_ready({true, false, active, active, active, true, true},
            [view] { view->fixture->service->start(); });
    }), &reopened);
    g_application_activate(application);
    ASSERT_EQ(reopened.created, 1);
    ASSERT_EQ(fixture.transport->registrations.load(), 0);
    g_object_unref(application);
    fixture.controller->set_observer([&] { ++new_window_updates; }); // New window reads same controller.
    fixture.controller->retry();
    spin_until([&] { return fixture.controller->state().phase == Phase::Idle; });
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Idle);
    ASSERT_TRUE(new_window_updates > 0); ASSERT_FALSE(fixture.held);
    ASSERT_EQ(fixture.transport->calls.load(), 1);
    ASSERT_FALSE(fixture.backend->read("record_id").has_value());
}

TEST(removal_controller_cancel_verifies_and_removes_ambiguous_marker) {
    using Phase = pux::ui::RemovalController::Phase;
    RemovalFixture fixture; fixture.backend->commit_then_fail = true;
    fixture.begin();
    spin_until([&] { return fixture.controller->state().phase == Phase::Unconfirmed; });
    ASSERT_TRUE(fixture.controller->state().can_cancel); ASSERT_TRUE(fixture.held);
    ASSERT_TRUE(fixture.backend->read(pux::storage::kRemovalIntentKey).has_value());
    fixture.backend->fail_marker_delete = true;
    fixture.controller->cancel();
    spin_until([&] { return fixture.controller->state().phase == Phase::Unconfirmed; });
    ASSERT_TRUE(fixture.held); ASSERT_TRUE(fixture.controller->state().can_cancel);
    ASSERT_TRUE(fixture.backend->read(pux::storage::kRemovalIntentKey).has_value());
    ASSERT_EQ(fixture.transport->calls.load(), 0);
    fixture.controller->cancel();
    spin_until([&] { return fixture.controller->state().phase == Phase::Idle; });
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Idle); ASSERT_FALSE(fixture.held);
    ASSERT_EQ(fixture.transport->calls.load(), 0);
    ASSERT_TRUE(fixture.backend->read("record_id").has_value());
    ASSERT_FALSE(fixture.backend->read(pux::storage::kRemovalIntentKey).has_value());
}

TEST(removal_controller_local_forget_works_without_a_prior_marker) {
    using Phase = pux::ui::RemovalController::Phase;
    RemovalFixture fixture;
    fixture.begin();
    spin_until([&] { return fixture.controller->state().phase == Phase::Unconfirmed; });
    ASSERT_TRUE(fixture.controller->state().can_cancel);
    ASSERT_FALSE(fixture.backend->read(pux::storage::kRemovalIntentKey).has_value());
    fixture.controller->forget_locally();
    spin_until([&] { return fixture.controller->state().phase == Phase::Idle; });
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Idle); ASSERT_FALSE(fixture.held);
    ASSERT_EQ(fixture.transport->calls.load(), 0);
    ASSERT_FALSE(fixture.backend->read("record_id").has_value());
    ASSERT_FALSE(fixture.backend->read(pux::storage::kRemovalIntentKey).has_value());
}

TEST(removal_controller_local_forget_clear_failure_keeps_local_intent) {
    using Phase = pux::ui::RemovalController::Phase;
    RemovalFixture fixture;
    fixture.begin();
    spin_until([&] { return fixture.controller->state().phase == Phase::Unconfirmed; });
    fixture.backend->fail_once = true;
    fixture.controller->forget_locally();
    spin_until([&] { return fixture.controller->state().phase == Phase::Durable; });
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Durable);
    ASSERT_FALSE(fixture.controller->state().can_cancel);
    auto marker = nlohmann::json::parse(fixture.backend->read(pux::storage::kRemovalIntentKey).value());
    ASSERT_EQ(marker.at("action").get<std::string>(), "local");
    ASSERT_EQ(fixture.transport->calls.load(), 0);
    fixture.controller->retry();
    spin_until([&] { return fixture.controller->state().phase == Phase::Idle; });
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Idle);
    ASSERT_FALSE(fixture.held); ASSERT_EQ(fixture.transport->calls.load(), 0);
    ASSERT_FALSE(fixture.backend->read("record_id").has_value());
}

TEST(removal_controller_durable_failure_cannot_resume_without_resolution) {
    using Phase = pux::ui::RemovalController::Phase;
    RemovalFixture fixture; fixture.backend->fail_marker = false; fixture.transport->fail_once = true;
    fixture.begin();
    spin_until([&] { return fixture.controller->state().phase == Phase::Durable; });
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Durable);
    ASSERT_FALSE(fixture.controller->state().can_cancel);
    ASSERT_TRUE(fixture.backend->read(pux::storage::kRemovalIntentKey).has_value());
    fixture.controller->cancel();
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Durable);
    fixture.controller->retry();
    spin_until([&] { return fixture.controller->state().phase == Phase::Idle; });
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Idle);
    ASSERT_EQ(fixture.transport->calls.load(), 2);
    ASSERT_FALSE(fixture.backend->read("record_id").has_value());
}

TEST(removal_controller_retries_snapshot_after_cleanup_without_repeating_delete) {
    using Phase = pux::ui::RemovalController::Phase;
    RemovalFixture fixture;
    fixture.backend->fail_marker = false;
    fixture.backend->fail_after_clear = true;
    fixture.begin();
    spin_until([&] { return fixture.controller->state().phase == Phase::Unconfirmed; });
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Unconfirmed);
    ASSERT_FALSE(fixture.controller->state().can_cancel);
    ASSERT_TRUE(fixture.held);
    ASSERT_EQ(fixture.transport->calls.load(), 1);
    ASSERT_FALSE(fixture.backend->read("record_id").has_value());
    fixture.controller->retry();
    spin_until([&] { return fixture.controller->state().phase == Phase::Idle; });
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Idle);
    ASSERT_FALSE(fixture.held);
    ASSERT_EQ(fixture.transport->calls.load(), 1);
    ASSERT_FALSE(fixture.snapshot->read("record_id").has_value());
}

TEST(removal_controller_wont_cancel_a_different_pending_intent) {
    using Phase = pux::ui::RemovalController::Phase;
    RemovalFixture fixture; fixture.backend->commit_then_fail = true;
    fixture.begin();
    spin_until([&] { return fixture.controller->state().phase == Phase::Unconfirmed; });
    auto marker = nlohmann::json::parse(fixture.backend->read(pux::storage::kRemovalIntentKey).value());
    marker["action"] = "device";
    fixture.backend->write(pux::storage::kRemovalIntentKey, marker.dump());
    fixture.controller->cancel();
    spin_until([&] { return fixture.controller->state().phase == Phase::Unconfirmed; });
    ASSERT_TRUE(fixture.held);
    ASSERT_TRUE(fixture.controller->state().can_cancel);
    ASSERT_TRUE(fixture.backend->read(pux::storage::kRemovalIntentKey).has_value());
    ASSERT_EQ(fixture.transport->calls.load(), 0);
    // Resolve the fixture without discarding the different marker.
    marker["action"] = "relay";
    fixture.backend->write(pux::storage::kRemovalIntentKey, marker.dump());
    fixture.controller->cancel();
    spin_until([&] { return fixture.controller->state().phase == Phase::Idle; });
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Idle);
    ASSERT_FALSE(fixture.held);
}

TEST(removal_controller_cancel_without_marker_preserves_enrollment) {
    using Phase = pux::ui::RemovalController::Phase;
    RemovalFixture fixture;
    fixture.begin();
    spin_until([&] { return fixture.controller->state().phase == Phase::Unconfirmed; });
    ASSERT_TRUE(fixture.controller->state().can_cancel);
    ASSERT_FALSE(fixture.backend->read(pux::storage::kRemovalIntentKey).has_value());
    fixture.controller->cancel();
    spin_until([&] { return fixture.controller->state().phase == Phase::Idle; });
    ASSERT_TRUE(fixture.controller->state().phase == Phase::Idle);
    ASSERT_FALSE(fixture.held); ASSERT_EQ(fixture.transport->calls.load(), 0);
    ASSERT_TRUE(fixture.backend->read("record_id").has_value());
}
