#include <gtk/gtk.h>
#include <memory>
#include <iostream>

#include "crypto/crypto.hpp"
#include "storage/secret_store.hpp"
#include "storage/record_store.hpp"
#include "api/api_client.hpp"
#include "notifications/notification_service.hpp"
#include "delivery/desktop_delivery_service.hpp"
#include "ui/app_window.hpp"
#include "ui/activation_gate.hpp"

namespace {

struct AppContext {
    std::shared_ptr<pux::storage::RecordStore> record_store;
    std::shared_ptr<pux::storage::StorageCoordinator> storage;
    std::shared_ptr<pux::api::ApiClient> api_client;
    std::shared_ptr<pux::notifications::NotificationService> notification_service;
    std::shared_ptr<pux::delivery::DesktopDeliveryService> delivery_service;
    std::shared_ptr<pux::ui::RemovalController> removal;
    std::unique_ptr<pux::ui::AppWindow> window;
};

void app_activate(GApplication* app, gpointer user_data) {
    auto* ctx = static_cast<AppContext*>(user_data);

    if (pux::ui::ensure_live_window(ctx->window,
        [](const pux::ui::AppWindow& window) { return window.gtk_window() != nullptr; },
        [&] { return std::make_unique<pux::ui::AppWindow>(
            GTK_APPLICATION(app),
            ctx->record_store,
            ctx->api_client,
            ctx->delivery_service,
            ctx->notification_service,
            ctx->storage,
            ctx->removal
        ); })) {

        ctx->notification_service->set_window_activator([app]() {
            g_application_activate(app);
        });

        ctx->delivery_service->set_held_callback([ctx](
            const std::vector<pux::delivery::HeldDelivery>&,
            const std::vector<pux::delivery::HeldDelivery>&
        ) {
            if (ctx->window) {
                ctx->window->update_home_live();
            }
        });

        ctx->delivery_service->set_status_callback([ctx](
            const pux::delivery::DeliveryStatus& status
        ) {
            if (ctx->window) {
                ctx->window->on_delivery_status_changed(status);
            }
        });
    }

    ctx->window->show();
    ctx->window->present();

}

} // namespace

int main(int argc, char** argv) {
    try {
        pux::crypto::init();
    } catch (const std::exception& e) {
        std::cerr << "Failed to initialize crypto: " << e.what() << "\n";
        return 1;
    }

    GtkApplication* app = gtk_application_new("xyz.vidur.pux", static_cast<GApplicationFlags>(0));

    auto secret_store = pux::storage::create_default_secret_store();
    auto snapshot = std::make_shared<pux::storage::MemorySecretStore>();
    auto storage = std::make_shared<pux::storage::StorageCoordinator>(secret_store, snapshot);
    auto record_store = std::make_shared<pux::storage::RecordStore>(snapshot);

    auto api_client = std::make_shared<pux::api::ApiClient>();
    auto notification_service = std::make_shared<pux::notifications::NotificationService>();
    auto delivery_service = std::make_shared<pux::delivery::DesktopDeliveryService>(
        record_store,
        api_client,
        notification_service,
        pux::delivery::DeliveryTiming{}, storage
    );
    auto application_ref = std::shared_ptr<GApplication>(G_APPLICATION(g_object_ref(app)), [](GApplication* application) { g_object_unref(application); });
    auto removal = std::make_shared<pux::ui::RemovalController>(storage, api_client, delivery_service,
        [application_ref](bool held) { if (held) g_application_hold(application_ref.get()); else g_application_release(application_ref.get()); });

    AppContext ctx{
        record_store,
        storage,
        api_client,
        notification_service,
        delivery_service,
        removal,
        nullptr
    };

    g_signal_connect(app, "activate", G_CALLBACK(app_activate), &ctx);

    int status = g_application_run(G_APPLICATION(app), argc, argv);

    delivery_service->set_status_callback(nullptr);
    delivery_service->set_held_callback(nullptr);
    delivery_service->stop();
    ctx.window = nullptr;

    g_object_unref(app);

    return status;
}
