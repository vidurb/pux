#include "test_harness.hpp"
#include "../src/ui/app_window.hpp"
#include "../src/crypto/crypto.hpp"
#include "../src/notifications/notification_service.hpp"
#include "../src/api/api_client.hpp"

#if defined(__linux__) && defined(PUX_LINUX_TESTING)

#include <gtk/gtk.h>
#include <atomic>
#include <chrono>
#include <thread>

namespace {

constexpr const char* kTestServerUrl = "http://127.0.0.1:9";

class NullNotificationService : public pux::notifications::NotificationService {
public:
    bool show(const pux::notifications::RelayNotification&) override { return true; }
};

class LocalhostOnlyHttpTransport : public pux::api::HttpTransport {
public:
    std::atomic<int> requests{0};

    pux::api::HttpResponse request(
        const std::string& method,
        const std::string& url,
        const std::vector<std::string>& /*headers*/,
        const std::string& /*body*/,
        long /*timeout_seconds*/
    ) override {
        ++requests;
        if (url.find("127.0.0.1") == std::string::npos && url.find("localhost") == std::string::npos) {
            throw pux::api::ApiException("test transport blocked non-local URL: " + url);
        }
        if (method == "POST" && url.find("/record/devices") != std::string::npos) {
            return {200, "{\"device_id\":\"test-device-id\"}"};
        }
        if (method == "GET" && url.find("/pending") != std::string::npos) {
            return {200, "[]"};
        }
        return {404, "{}"};
    }
};

void seed_enrollment(const std::shared_ptr<pux::storage::MemorySecretStore>& mem) {
    pux::crypto::init();
    auto kp = pux::crypto::generate_key_pair();
    mem->write("record_id", "11111111-2222-3333-4444-555555555555");
    mem->write("private_key", kp.private_key);
    mem->write("public_key", kp.public_key);
    mem->write("inbox", "inbox@example.com");
    mem->write("server_url", kTestServerUrl);
    mem->write("device_id", "device-1");
}

// Relay at its device cap until `at_limit` is cleared.
class DeviceLimitHttpTransport final : public pux::api::HttpTransport {
public:
    std::atomic<bool> at_limit{true};
    std::atomic<int> registrations{0};

    pux::api::HttpResponse request(
        const std::string& method,
        const std::string& url,
        const std::vector<std::string>&,
        const std::string&,
        long
    ) override {
        if (method == "POST" && url.find("/record/devices") != std::string::npos) {
            ++registrations;
            if (at_limit) return {422, "{\"error\":\"too_many_devices\"}"};
            return {200, "{\"device_id\":\"freed-slot-device\"}"};
        }
        if (method == "GET" && url.find("/record/deliveries") != std::string::npos) {
            return {200, "{\"deliveries\":[]}"};
        }
        return {404, "{}"};
    }
};

GtkWidget* find_button_by_accessible_name(GtkWidget* root, const std::string& name) {
    if (!root) return nullptr;
    if (GTK_IS_BUTTON(root)) {
        if (AtkObject* atk = gtk_widget_get_accessible(root)) {
            const char* accessible_name = atk_object_get_name(atk);
            if (accessible_name && name == accessible_name) return root;
        }
    }
    if (GTK_IS_CONTAINER(root)) {
        GList* children = gtk_container_get_children(GTK_CONTAINER(root));
        GtkWidget* found = nullptr;
        for (GList* l = children; l != nullptr && !found; l = l->next) {
            found = find_button_by_accessible_name(GTK_WIDGET(l->data), name);
        }
        g_list_free(children);
        return found;
    }
    return nullptr;
}

template <class Pred>
bool pump_gtk_until(std::chrono::milliseconds limit, Pred done) {
    const auto deadline = std::chrono::steady_clock::now() + limit;
    while (std::chrono::steady_clock::now() < deadline) {
        while (g_main_context_iteration(nullptr, FALSE)) {}
        if (done()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    while (g_main_context_iteration(nullptr, FALSE)) {}
    return done();
}

GtkApplication* register_test_application() {
    // GTK exports a process-wide profiler object on the session bus. Creating
    // another GtkApplication before that export has been released fails on
    // GTK builds with sysprof enabled, so these tests share one application.
    static GtkApplication* app = []() -> GtkApplication* {
        GtkApplication* instance = gtk_application_new("xyz.vidur.pux.test.views", G_APPLICATION_NON_UNIQUE);
        GError* error = nullptr;
        if (!g_application_register(G_APPLICATION(instance), nullptr, &error)) {
            if (error) {
                std::cerr << "GTK application registration failed: " << error->message << std::endl;
                g_error_free(error);
            }
            g_object_unref(instance);
            return nullptr;
        }
        return instance;
    }();
    if (!app) return nullptr;
    g_object_ref(app);
    g_application_hold(G_APPLICATION(app));
    return app;
}

} // namespace

TEST(app_window_survives_repeated_view_refresh) {
    if (!gtk_init_check(nullptr, nullptr)) return;

    GtkApplication* app = register_test_application();
    if (!app) SKIP_TEST("GTK application could not register");

    auto transport = std::make_shared<LocalhostOnlyHttpTransport>();
    auto api = std::make_shared<pux::api::ApiClient>(transport);

    auto mem = std::make_shared<pux::storage::MemorySecretStore>();
    seed_enrollment(mem);
    auto record = std::make_shared<pux::storage::RecordStore>(mem);
  record->init();

    auto delivery = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record,
        api,
        std::make_shared<NullNotificationService>(),
        pux::delivery::DeliveryTiming{});

    pux::ui::AppWindow window(
        app,
        record,
        api,
        delivery,
        std::make_shared<NullNotificationService>(),
        nullptr,
        nullptr
    );

    window.refresh_views();
    ASSERT_TRUE(window.test_content_box() != nullptr);
    ASSERT_TRUE(window.test_content_child_count() > 0);
    ASSERT_TRUE(window.test_view_mode() == pux::ui::AppWindow::ViewMode::Home);

    for (int i = 0; i < 5; ++i) {
        window.refresh_views();
        ASSERT_TRUE(window.test_content_child_count() > 0);
    }

    pux::delivery::DeliveryStatus status;
    status.state = pux::delivery::DeliveryState::Retrying;
    status.message = "offline";
    window.on_delivery_status_changed(status);
    ASSERT_TRUE(window.test_view_mode() == pux::ui::AppWindow::ViewMode::Home);
    ASSERT_TRUE(window.test_content_child_count() > 0);

    delivery->stop();
    gtk_widget_destroy(GTK_WIDGET(window.gtk_window()));

    g_application_release(G_APPLICATION(app));
    g_object_unref(app);
}


TEST(app_window_enrollment_editor_has_explicit_accessible_name) {
    if (!gtk_init_check(nullptr, nullptr)) SKIP_TEST("GTK display unavailable");
    GtkApplication* app = register_test_application();
    if (!app) SKIP_TEST("GTK application could not register");

    auto transport = std::make_shared<LocalhostOnlyHttpTransport>();
    auto api = std::make_shared<pux::api::ApiClient>(transport);
    auto record = std::make_shared<pux::storage::RecordStore>(std::make_shared<pux::storage::MemorySecretStore>());
    record->init();
    auto delivery = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record, api, std::make_shared<NullNotificationService>(), pux::delivery::DeliveryTiming{});
    {
        pux::ui::AppWindow window(app, record, api, delivery, std::make_shared<NullNotificationService>(), nullptr, nullptr);
        ASSERT_TRUE(window.test_view_mode() == pux::ui::AppWindow::ViewMode::Setup);

        auto check_editor_name = [&] {
            GtkTextView* editor = window.test_import_text_view();
            ASSERT_TRUE(editor != nullptr);
            AtkObject* atk = gtk_widget_get_accessible(GTK_WIDGET(editor));
            ASSERT_TRUE(atk != nullptr);
            const char* name = atk_object_get_name(atk);
            ASSERT_TRUE(name != nullptr);
            ASSERT_EQ(std::string(name), std::string("Enrollment JSON"));
            // The instructions are attached as its description.
            AtkRelationSet* relations = atk_object_ref_relation_set(atk);
            ASSERT_TRUE(relations != nullptr);
            const bool described = atk_relation_set_contains(relations, ATK_RELATION_DESCRIBED_BY);
            g_object_unref(relations);
            ASSERT_TRUE(described);
        };
        check_editor_name();
        // The editor is rebuilt on every refresh; the name must come back each time.
        window.refresh_views();
        check_editor_name();
        gtk_widget_destroy(GTK_WIDGET(window.gtk_window()));
    }
    delivery->stop();
    g_application_release(G_APPLICATION(app));
    g_object_unref(app);
}

TEST(app_window_device_limit_banner_retry_reregisters_after_slot_freed) {
    using namespace std::chrono_literals;
    if (!gtk_init_check(nullptr, nullptr)) SKIP_TEST("GTK display unavailable");
    GtkApplication* app = register_test_application();
    if (!app) SKIP_TEST("GTK application could not register");

    auto transport = std::make_shared<DeviceLimitHttpTransport>();
    auto api = std::make_shared<pux::api::ApiClient>(transport);
    auto mem = std::make_shared<pux::storage::MemorySecretStore>();
    seed_enrollment(mem);
    mem->delete_key("device_id");
    auto record = std::make_shared<pux::storage::RecordStore>(mem);
    record->init();
    // An hour until the automatic retry, so only the button can recover here.
    pux::delivery::DeliveryTiming timing{1h, 1h, 1h, 1h};
    timing.registration_retry = 1h;
    timing.registration_retry_max = 1h;
    auto delivery = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record, api, std::make_shared<NullNotificationService>(), timing);
    {
        pux::ui::AppWindow window(app, record, api, delivery, std::make_shared<NullNotificationService>(), nullptr, nullptr);
        delivery->set_status_callback([&window](const pux::delivery::DeliveryStatus& status) {
            window.on_delivery_status_changed(status);
        });
        window.refresh_views();   // enrolled: starts delivery, registration is refused
        ASSERT_TRUE(window.test_view_mode() == pux::ui::AppWindow::ViewMode::Home);

        auto retry_button = [&] {
            return find_button_by_accessible_name(window.test_content_box(), "Retry registration");
        };
        ASSERT_TRUE(pump_gtk_until(5s, [&] { return retry_button() != nullptr; }));
        ASSERT_EQ(transport->registrations.load(), 1);
        ASSERT_TRUE(delivery->status().state == pux::delivery::DeliveryState::TooManyDevices);

        // Clicking while the relay is still full registers again and the banner returns.
        gtk_button_clicked(GTK_BUTTON(retry_button()));
        ASSERT_TRUE(pump_gtk_until(5s, [&] { return transport->registrations.load() == 2 && retry_button() != nullptr; }));
        // Keyboard and screen-reader users keep their place: the rebuilt button has focus.
        ASSERT_TRUE(pump_gtk_until(2s, [&] { return gtk_window_get_focus(window.gtk_window()) == retry_button(); }));

        // A slot is freed elsewhere: Retry registers, saves the device and withdraws the error.
        transport->at_limit = false;
        gtk_button_clicked(GTK_BUTTON(retry_button()));
        ASSERT_TRUE(pump_gtk_until(5s, [&] { return record->device_id().value_or("") == "freed-slot-device"; }));
        ASSERT_TRUE(pump_gtk_until(5s, [&] { return retry_button() == nullptr; }));
        ASSERT_EQ(transport->registrations.load(), 3);
        ASSERT_TRUE(delivery->status().state != pux::delivery::DeliveryState::TooManyDevices);

        delivery->set_status_callback(nullptr);
        delivery->stop();
        gtk_widget_destroy(GTK_WIDGET(window.gtk_window()));
    }
    g_application_release(G_APPLICATION(app));
    g_object_unref(app);
}

#endif
