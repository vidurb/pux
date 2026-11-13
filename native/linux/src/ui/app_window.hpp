#pragma once

#include <gtk/gtk.h>
#include <memory>
#include <functional>
#include <optional>
#include <vector>
#include "../storage/record_store.hpp"
#include "../storage/storage_coordinator.hpp"
#include "../api/api_client.hpp"
#include "../delivery/desktop_delivery_service.hpp"
#include "../notifications/notification_service.hpp"
#include "removal_controller.hpp"

namespace pux {
namespace ui {

class AppWindow {
public:
    AppWindow(
        GtkApplication* app,
        std::shared_ptr<storage::RecordStore> record_store,
        std::shared_ptr<api::ApiClient> api_client,
        std::shared_ptr<delivery::DesktopDeliveryService> delivery_service,
        std::shared_ptr<notifications::NotificationService> notification_service,
        std::shared_ptr<storage::StorageCoordinator> storage = nullptr,
        std::shared_ptr<RemovalController> removal = nullptr
    );
    ~AppWindow();

    void show();
    void present();

    GtkWindow* gtk_window() const { return window_; }

    enum class ViewMode { None, Loading, KeyringError, Setup, Home };

    void refresh_views();
    void update_home_live();
    void on_delivery_status_changed(const delivery::DeliveryStatus& status);
    void on_window_destroyed();

private:
    GtkApplication* app_;
    std::shared_ptr<storage::RecordStore> record_store_;
    std::shared_ptr<api::ApiClient> api_client_;
    std::shared_ptr<delivery::DesktopDeliveryService> delivery_service_;
    std::shared_ptr<notifications::NotificationService> notification_service_;
    std::shared_ptr<storage::StorageCoordinator> storage_;
    std::shared_ptr<RemovalController> removal_;
    bool storage_loading_ = false;
    bool recovery_pending_ = false;
    std::string storage_error_;
    void load_storage();
    void forget_pending_locally();
    void reset_corrupt_keyring();
    void on_removal_changed();

    GtkWindow* window_ = nullptr;
    GtkHeaderBar* header_bar_ = nullptr;
    GtkWidget* main_container_ = nullptr;
    GtkWidget* content_box_ = nullptr;
    GtkWidget* home_dynamic_box_ = nullptr;

    ViewMode view_mode_ = ViewMode::None;

    GtkTextView* import_text_view_ = nullptr;
    GtkLabel* import_error_label_ = nullptr;

    bool show_qr_ = false;
    bool removing_ = false;
    delivery::DeliveryStatus current_status_;
    struct HomeDynamicSnapshot {
        delivery::DeliveryState state = delivery::DeliveryState::Idle;
        std::string message;
        size_t undecryptable_count = 0;
        std::vector<std::string> held_ids;
        std::vector<std::string> recent_ids;
        bool operator==(const HomeDynamicSnapshot& other) const;
    };
    std::optional<HomeDynamicSnapshot> home_dynamic_snapshot_;
    std::string restore_focus_delivery_id_;
    std::shared_ptr<std::atomic<bool>> alive_;
    std::shared_ptr<std::atomic<bool>> enrollment_alive_ = std::make_shared<std::atomic<bool>>(true);
    bool removal_in_progress_ = false;
    bool refocus_registration_retry_ = false;
    bool post_success_notice_dialog_active_ = false;

    // View builders
    void build_ui();
    void build_setup_view();
    void build_home_view();
    void rebuild_home_dynamic_sections();
    void apply_error_label_style(GtkWidget* label);

    // Dialogs & actions
    void on_import_clicked();
    void on_copy_inbox_clicked();
    void on_how_to_forward_clicked();
    void on_send_test_code_clicked();
    void on_toggle_qr_clicked();
    void on_copy_enrollment_json_clicked();
    void on_remove_device_clicked();
    void on_delete_relay_clicked();
    void on_refresh_health_clicked();
    void on_retry_registration_clicked();

    void remove_with(
        const std::string& failure_title,
        const std::string& forget_warning,
        const std::string& action
    );

    bool confirm_server_dialog(const std::string& server_url);
    bool confirm_copy_json_dialog();
    bool confirm_delete_relay_dialog();

#if defined(PUX_LINUX_TESTING)
public:
    int test_content_child_count() const;
    ViewMode test_view_mode() const { return view_mode_; }
    GtkWidget* test_content_box() const { return content_box_; }
    GtkTextView* test_import_text_view() const { return import_text_view_; }
#endif
};

} // namespace ui
} // namespace pux
