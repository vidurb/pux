#include "app_window.hpp"
#include "activation_gate.hpp"
#include "removal_flow.hpp"
#include "../storage/removal_intent.hpp"
#include "../clipboard/sensitive_clipboard.hpp"
#include "../vendor/qrcodegen.hpp"
#include <iostream>
#include <thread>

namespace pux {
namespace ui {

namespace {

void show_info_dialog(GtkWindow* parent, const std::string& title, const std::string& message) {
    GtkWidget* dialog = gtk_message_dialog_new(
        parent,
        GTK_DIALOG_MODAL,
        GTK_MESSAGE_INFO,
        GTK_BUTTONS_OK,
        "%s", title.c_str()
    );
    gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog), "%s", message.c_str());
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
}

constexpr const char* kEnrollmentEditorAccessibleName = "Enrollment JSON";
constexpr const char* kRetryRegistrationLabel = "Retry registration";

struct WindowTask {
    std::weak_ptr<std::atomic<bool>> alive;
    std::function<void()> fn;
};

void gtk_container_remove_all_children(GtkWidget* container) {
    GList* children = gtk_container_get_children(GTK_CONTAINER(container));
    for (GList* l = children; l != nullptr; l = l->next) {
        gtk_widget_destroy(GTK_WIDGET(l->data));
    }
    g_list_free(children);
}

void post_to_main_thread(std::weak_ptr<std::atomic<bool>> alive, std::function<void()> fn) {
    auto* holder = new WindowTask{std::move(alive), std::move(fn)};
    g_idle_add([](gpointer data) -> gboolean {
        auto* t = static_cast<WindowTask*>(data);
        if (auto a = t->alive.lock()) {
            if (a->load()) {
                try { t->fn(); }
                catch (const std::exception& e) { std::cerr << "Window callback failed: " << e.what() << "\n"; }
                catch (...) { std::cerr << "Window callback failed\n"; }
            }
        }
        delete t;
        return G_SOURCE_REMOVE;
    }, holder);
}

} // namespace

AppWindow::AppWindow(
    GtkApplication* app,
    std::shared_ptr<storage::RecordStore> record_store,
    std::shared_ptr<api::ApiClient> api_client,
    std::shared_ptr<delivery::DesktopDeliveryService> delivery_service,
    std::shared_ptr<notifications::NotificationService> notification_service,
    std::shared_ptr<storage::StorageCoordinator> storage,
    std::shared_ptr<RemovalController> removal
) : app_(app),
    record_store_(std::move(record_store)),
    api_client_(std::move(api_client)),
    delivery_service_(std::move(delivery_service)),
    notification_service_(std::move(notification_service)),
    storage_(std::move(storage)), removal_(std::move(removal)), storage_loading_(storage_ != nullptr),
    alive_(std::make_shared<std::atomic<bool>>(true)) {
    build_ui();
    if (removal_) {
        auto alive = alive_;
        removal_->set_observer([this, alive] { if (alive->load()) on_removal_changed(); });
    }
    if (removal_ && removal_->state().phase != RemovalController::Phase::Idle) on_removal_changed();
    else if (storage_) load_storage();
}

AppWindow::~AppWindow() {
    if (alive_) {
        *alive_ = false;
    }
    *enrollment_alive_ = false;
    if (removal_) removal_->set_observer(nullptr);
}

void AppWindow::show() {
    if (window_) {
        gtk_widget_show_all(GTK_WIDGET(window_));
    }
}

void AppWindow::present() {
    if (window_) {
        gtk_window_present(window_);
    }
}

void AppWindow::build_ui() {
    window_ = GTK_WINDOW(gtk_application_window_new(app_));
    gtk_window_set_default_size(window_, 640, 720);
    gtk_window_set_position(window_, GTK_WIN_POS_CENTER);

    header_bar_ = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_header_bar_set_show_close_button(header_bar_, TRUE);
    gtk_window_set_titlebar(window_, GTK_WIDGET(header_bar_));

    main_container_ = gtk_scrolled_window_new(nullptr, nullptr);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(main_container_), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_container_add(GTK_CONTAINER(window_), main_container_);

    GtkCssProvider* css = gtk_css_provider_new();
    gtk_css_provider_load_from_data(css,
        "label.error-label { color: #c01c28; }\n"
        "button.destructive-action { background-image: none; background-color: #c01c28; color: #ffffff; }\n",
        -1, nullptr);
    gtk_style_context_add_provider_for_screen(
        gdk_screen_get_default(),
        GTK_STYLE_PROVIDER(css),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
    );
    g_object_unref(css);

    GtkIconTheme* theme = gtk_icon_theme_get_default();
    if (gtk_icon_theme_has_icon(theme, "xyz.vidur.pux")) {
        gtk_window_set_icon_name(window_, "xyz.vidur.pux");
    }

    content_box_ = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_container_set_border_width(GTK_CONTAINER(content_box_), 24);
    gtk_container_add(GTK_CONTAINER(main_container_), content_box_);

    g_signal_connect(window_, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer user_data) {
        auto* self = static_cast<AppWindow*>(user_data);
        if (self) {
            self->on_window_destroyed();
        }
    }), this);

    refresh_views();
}

void AppWindow::on_window_destroyed() {
    if (alive_) {
        *alive_ = false;
    }
    window_ = nullptr;
    *enrollment_alive_ = false;
    if (removal_) removal_->set_observer(nullptr);
    delivery_service_->set_status_callback(nullptr);
    delivery_service_->set_held_callback(nullptr);
}

void AppWindow::on_removal_changed() {
    if (!removal_ || !alive_->load() || !window_) return;
    const auto& state = removal_->state();
    if (state.phase == RemovalController::Phase::Idle && !state.post_success_notice.empty() &&
        !post_success_notice_dialog_active_) {
        post_success_notice_dialog_active_ = true;
        const std::string notice = state.post_success_notice;
        show_info_dialog(window_, "Device removed", notice);
        post_success_notice_dialog_active_ = false;
        if (!alive_->load() || !window_ || !removal_) return;
        auto alive = alive_;
        removal_->clear_post_success_notice([this, alive](const std::string& error) {
            if (!alive->load() || !window_) return;
            if (!error.empty()) {
                storage_error_ = "Could not clear the removal warning from the keyring.\n\n" + error;
                if (removal_) {
                    removal_->restore_post_removal_notice_from_store(*record_store_);
                }
            }
            refresh_views();
        });
    }
    storage_loading_ = state.phase == RemovalController::Phase::Running;
    removal_in_progress_ = state.phase != RemovalController::Phase::Idle;
    recovery_pending_ = state.phase == RemovalController::Phase::Unconfirmed || state.phase == RemovalController::Phase::Durable;
    if (recovery_pending_) {
        if (state.can_cancel)
            storage_error_ = "The removal intent could not be confirmed in the keyring; no server removal was attempted. "
                "The app remains running if this window closes. A forced exit could lose this request. "
                "Retry, cancel removal, or forget locally.\n\n" + state.error;
        else
            storage_error_ = "Removal is unresolved; the server outcome may be unknown. Retry or forget locally. "
                "If the local-only choice could not be saved, the earlier removal may retry after a forced exit.\n\n" + state.error;
    } else storage_error_.clear();
    refresh_views();
}

void AppWindow::load_storage() {
    if (!storage_) return;
    storage_loading_ = true;
    storage_error_.clear();
    refresh_views();
    auto* application = G_APPLICATION(g_object_ref(app_));
    g_application_hold(application);
    auto alive = alive_;
    auto api = api_client_;
    auto pending = std::make_shared<std::atomic<bool>>(false);
    storage_->submit_durable([api, pending](storage::RecordStore& store) {
        *pending = store.secret_store()->read(storage::kRemovalIntentKey).has_value();
        storage::recover_removal(store, *api);
        if (store.is_enrolled()) store.desktop_device_id();
    },
        [this, alive, application, pending](const std::string& error) {
            if (alive->load()) {
                storage_loading_ = false;
                storage_error_ = error;
                recovery_pending_ = !error.empty() && pending->load();
                if (error.empty() && removal_) {
                    removal_->restore_post_removal_notice_from_store(*record_store_);
                }
                refresh_views();
            }
            g_application_release(application);
            g_object_unref(application);
        });
}

void AppWindow::forget_pending_locally() {
    if (!storage_ || storage_loading_ || !recovery_pending_) return;
    GtkWidget* dialog = gtk_message_dialog_new(window_, GTK_DIALOG_MODAL, GTK_MESSAGE_WARNING,
        GTK_BUTTONS_OK_CANCEL, "Forget this relay locally?");
    gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog), "%s",
        "The server removal may not have succeeded. The device or relay may remain active, "
        "and other devices may continue receiving codes. This removes the local keys and stops retrying the server removal.");
    auto response = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    if (response != GTK_RESPONSE_OK || !alive_->load() || !window_) return;
    if (removal_ && removal_->state().phase != RemovalController::Phase::Idle) {
        removal_->forget_locally();
        return;
    }
    storage_loading_ = true;
    refresh_views();
    auto alive = alive_;
    auto service = delivery_service_;
    auto* application = G_APPLICATION(g_object_ref(app_));
    g_application_hold(application);
    storage_->submit_durable([](storage::RecordStore& store) { storage::forget_pending_locally(store); },
        [this, alive, service, application](const std::string& error) {
            if (error.empty()) service->stop();
            if (alive->load()) {
                storage_loading_ = false;
                storage_error_ = error;
                recovery_pending_ = !error.empty();
                removal_in_progress_ = false;
                refresh_views();
            }
            g_application_release(application);
            g_object_unref(application);
        });
}

void AppWindow::reset_corrupt_keyring() {
    if (!storage_ || storage_loading_) return;
    GtkWidget* dialog = gtk_message_dialog_new(
        window_,
        GTK_DIALOG_MODAL,
        GTK_MESSAGE_WARNING,
        GTK_BUTTONS_OK_CANCEL,
        "Clear corrupted keyring data?");
    gtk_message_dialog_format_secondary_text(
        GTK_MESSAGE_DIALOG(dialog),
        "%s",
        "This removes the broken enrollment data this app stored in your keyring. "
        "It does not delete a separate legacy Flutter item; use Retry if migration is still pending.");
    const auto response = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    if (response != GTK_RESPONSE_OK || !alive_->load() || !window_) return;

    storage_loading_ = true;
    refresh_views();
    auto alive = alive_;
    auto service = delivery_service_;
    auto* application = G_APPLICATION(g_object_ref(app_));
    g_application_hold(application);
    storage_->submit_reset_corrupt_native([this, alive, service, application](const std::string& error) {
            if (error.empty()) service->stop();
            if (alive->load()) {
                storage_loading_ = false;
                storage_error_ = error;
                recovery_pending_ = false;
                removal_in_progress_ = false;
                refresh_views();
            }
            g_application_release(application);
            g_object_unref(application);
        });
}

void AppWindow::on_delivery_status_changed(const delivery::DeliveryStatus& status) {
    current_status_ = status;
    post_to_main_thread(alive_, [this]() {
        if (!alive_->load() || !window_) return;
        update_home_live();
    });
}

void AppWindow::apply_error_label_style(GtkWidget* label) {
    gtk_widget_set_name(label, "error-label");
    GtkStyleContext* ctx = gtk_widget_get_style_context(label);
    if (ctx) gtk_style_context_add_class(ctx, "error-label");
}

bool AppWindow::HomeDynamicSnapshot::operator==(const HomeDynamicSnapshot& other) const {
    return state == other.state && message == other.message &&
           undecryptable_count == other.undecryptable_count &&
           held_ids == other.held_ids && recent_ids == other.recent_ids;
}

#if defined(PUX_LINUX_TESTING)
int AppWindow::test_content_child_count() const {
    if (!content_box_) return 0;
    int count = 0;
    GList* children = gtk_container_get_children(GTK_CONTAINER(content_box_));
    for (GList* l = children; l != nullptr; l = l->next) ++count;
    g_list_free(children);
    return count;
}
#endif

void AppWindow::update_home_live() {
    if (!alive_->load() || !window_) return;
    if (view_mode_ == ViewMode::Home && home_dynamic_box_) {
        rebuild_home_dynamic_sections();
        if (home_dynamic_box_) gtk_widget_show_all(home_dynamic_box_);
        return;
    }
    refresh_views();
}

void AppWindow::refresh_views() {
    if (!alive_->load() || !window_) return;
    if (!content_box_) return;

    gtk_container_remove_all_children(content_box_);
    home_dynamic_box_ = nullptr;
    home_dynamic_snapshot_.reset();

    import_text_view_ = nullptr;
    import_error_label_ = nullptr;

    // Clear header bar child widgets
    GList* children = gtk_container_get_children(GTK_CONTAINER(header_bar_));
    for (GList* l = children; l != nullptr; l = l->next) {
        gtk_widget_destroy(GTK_WIDGET(l->data));
    }
    g_list_free(children);

    if (storage_loading_) {
        view_mode_ = ViewMode::Loading;
        gtk_header_bar_set_title(header_bar_, "pux");
        gtk_header_bar_set_subtitle(header_bar_, nullptr);
        gtk_box_pack_start(GTK_BOX(content_box_), gtk_label_new(removal_in_progress_ ? "Completing removal…" : "Loading keyring…"), FALSE, FALSE, 16);
        gtk_widget_show_all(GTK_WIDGET(window_));
        return;
    }

    bool enrolled = false;
    std::string keyring_error = storage_error_;
    try {
        record_store_->init();
        enrolled = record_store_->is_enrolled();
    } catch (const storage::KeyringUnavailableException& e) {
        keyring_error = e.what();
    } catch (const storage::KeyringLockedException& e) {
        keyring_error = e.what();
    } catch (const storage::KeyringCorruptException& e) {
        keyring_error = e.what();
    } catch (const storage::LegacyEnrollmentPendingException& e) {
        keyring_error = e.what();
    } catch (const std::exception& e) {
        keyring_error = e.what();
    }

    const bool show_clear_corrupt =
        !keyring_error.empty() && !recovery_pending_ && storage_ && storage_->corrupt_native_reset_allowed();

    if (!keyring_error.empty()) {
        view_mode_ = ViewMode::KeyringError;
        gtk_header_bar_set_title(header_bar_, recovery_pending_ ? "pux - Removal Pending" : "pux - Keyring Unavailable");
        gtk_header_bar_set_subtitle(header_bar_, nullptr);

        GtkWidget* err_title = gtk_label_new(recovery_pending_ ? "Removal pending" : "Keyring Error");
        PangoAttrList* attrs = pango_attr_list_new();
        pango_attr_list_insert(attrs, pango_attr_weight_new(PANGO_WEIGHT_BOLD));
        pango_attr_list_insert(attrs, pango_attr_scale_new(1.2));
        gtk_label_set_attributes(GTK_LABEL(err_title), attrs);
        pango_attr_list_unref(attrs);
        gtk_label_set_xalign(GTK_LABEL(err_title), 0.0f);
        gtk_box_pack_start(GTK_BOX(content_box_), err_title, FALSE, FALSE, 0);

        GtkWidget* err_msg = gtk_label_new(keyring_error.c_str());
        gtk_label_set_line_wrap(GTK_LABEL(err_msg), TRUE);
        gtk_label_set_line_wrap_mode(GTK_LABEL(err_msg), PANGO_WRAP_WORD_CHAR);
        gtk_label_set_xalign(GTK_LABEL(err_msg), 0.0f);
        gtk_box_pack_start(GTK_BOX(content_box_), err_msg, FALSE, FALSE, 0);

        GtkWidget* retry_btn = gtk_button_new_with_label(recovery_pending_ ? "Try again" : "Retry");
        gtk_widget_set_can_default(retry_btn, TRUE);
        g_signal_connect_swapped(retry_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
            if (self->removal_ && self->removal_->state().phase != RemovalController::Phase::Idle) self->removal_->retry();
            else if (self->storage_) self->load_storage(); else self->refresh_views();
        }), this);
        gtk_box_pack_start(GTK_BOX(content_box_), retry_btn, FALSE, FALSE, 8);
        if (show_clear_corrupt) {
            GtkWidget* clear_btn = gtk_button_new_with_label("Clear corrupted data");
            g_signal_connect_swapped(clear_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
                self->reset_corrupt_keyring();
            }), this);
            gtk_box_pack_start(GTK_BOX(content_box_), clear_btn, FALSE, FALSE, 8);
        }
        if (recovery_pending_) {
            GtkWidget* forget_btn = gtk_button_new_with_label("Forget locally anyway");
            g_signal_connect_swapped(forget_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
                self->forget_pending_locally();
            }), this);
            gtk_box_pack_start(GTK_BOX(content_box_), forget_btn, FALSE, FALSE, 8);
            if (removal_ && removal_->state().can_cancel) {
                GtkWidget* cancel_btn = gtk_button_new_with_label("Cancel removal");
                g_signal_connect_swapped(cancel_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
                    self->removal_->cancel();
                }), this);
                gtk_box_pack_start(GTK_BOX(content_box_), cancel_btn, FALSE, FALSE, 8);
            }
        }
    } else if (enrolled) {
        start_delivery_if_ready({window_ != nullptr && alive_->load(), storage_loading_,
            !storage_error_.empty(), removal_in_progress_, recovery_pending_, enrolled,
            delivery_service_->is_stopped()}, [this] { delivery_service_->start(); });
        build_home_view();
    } else {
        build_setup_view();
    }

    gtk_widget_show_all(GTK_WIDGET(window_));
}

void AppWindow::build_setup_view() {
    view_mode_ = ViewMode::Setup;
    gtk_header_bar_set_title(header_bar_, "Set up pux");
    gtk_header_bar_set_subtitle(header_bar_, nullptr);

    GtkWidget* intro = gtk_label_new(
        "Import an existing relay to receive OTP codes on this computer."
    );
    gtk_label_set_line_wrap(GTK_LABEL(intro), TRUE);
    gtk_label_set_line_wrap_mode(GTK_LABEL(intro), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(intro), 0.0f);
    gtk_box_pack_start(GTK_BOX(content_box_), intro, FALSE, FALSE, 0);

    GtkWidget* prompt = gtk_label_new(
        "Paste the enrollment JSON exported from a mobile device. "
        "Desktop clients receive OTP codes but do not generate keys."
    );
    gtk_label_set_line_wrap(GTK_LABEL(prompt), TRUE);
    gtk_label_set_line_wrap_mode(GTK_LABEL(prompt), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(prompt), 0.0f);
    gtk_box_pack_start(GTK_BOX(content_box_), prompt, FALSE, FALSE, 0);

    GtkWidget* text_view = gtk_text_view_new();
    import_text_view_ = GTK_TEXT_VIEW(text_view);
    gtk_text_view_set_accepts_tab(GTK_TEXT_VIEW(text_view), FALSE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(text_view), GTK_WRAP_WORD_CHAR);
    // Assistive technology otherwise announces an unnamed "text" editor. Name it
    // and point at the instructions above it, which describe what to paste.
    if (AtkObject* editor_atk = gtk_widget_get_accessible(text_view)) {
        atk_object_set_name(editor_atk, kEnrollmentEditorAccessibleName);
        if (AtkObject* prompt_atk = gtk_widget_get_accessible(prompt)) {
            atk_object_add_relationship(editor_atk, ATK_RELATION_DESCRIBED_BY, prompt_atk);
        }
    }
    GtkWidget* text_scroll = gtk_scrolled_window_new(nullptr, nullptr);
    gtk_scrolled_window_set_shadow_type(GTK_SCROLLED_WINDOW(text_scroll), GTK_SHADOW_IN);
    gtk_widget_set_size_request(text_scroll, -1, 180);
    gtk_container_add(GTK_CONTAINER(text_scroll), text_view);
    gtk_box_pack_start(GTK_BOX(content_box_), text_scroll, TRUE, TRUE, 0);

    GtkWidget* error_label = gtk_label_new("");
    import_error_label_ = GTK_LABEL(error_label);
    apply_error_label_style(error_label);
    gtk_label_set_line_wrap(GTK_LABEL(error_label), TRUE);
    gtk_label_set_line_wrap_mode(GTK_LABEL(error_label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(error_label), 0.0f);
    gtk_box_pack_start(GTK_BOX(content_box_), error_label, FALSE, FALSE, 0);

    GtkWidget* import_btn = gtk_button_new_with_mnemonic("_Import and connect");
    g_signal_connect_swapped(import_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
        self->on_import_clicked();
    }), this);
    gtk_box_pack_start(GTK_BOX(content_box_), import_btn, FALSE, FALSE, 0);

    GtkWidget* note = gtk_label_new(
        "Secrets are saved in the system keyring matching the pux Flutter client schema."
    );
    gtk_label_set_line_wrap(GTK_LABEL(note), TRUE);
    gtk_label_set_line_wrap_mode(GTK_LABEL(note), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(note), 0.0f);
    gtk_box_pack_start(GTK_BOX(content_box_), note, FALSE, FALSE, 8);
}

static GtkWidget* find_focus_widget_by_delivery_id(GtkWidget* root, const std::string& delivery_id) {
    if (!root || delivery_id.empty()) return nullptr;
    auto* stored = static_cast<std::string*>(g_object_get_data(G_OBJECT(root), "focus_delivery_id"));
    if (stored && *stored == delivery_id) return root;
    if (GTK_IS_CONTAINER(root)) {
        GList* children = gtk_container_get_children(GTK_CONTAINER(root));
        for (GList* l = children; l != nullptr; l = l->next) {
            if (GtkWidget* found = find_focus_widget_by_delivery_id(GTK_WIDGET(l->data), delivery_id)) {
                g_list_free(children);
                return found;
            }
        }
        g_list_free(children);
    }
    return nullptr;
}

void AppWindow::rebuild_home_dynamic_sections() {
    if (!home_dynamic_box_) return;

    HomeDynamicSnapshot snapshot;
    snapshot.state = current_status_.state;
    snapshot.message = current_status_.message;
    snapshot.undecryptable_count = current_status_.undecryptable_count;
    for (const auto& item : delivery_service_->held_deliveries()) snapshot.held_ids.push_back(item.delivery_id);
    for (const auto& item : delivery_service_->recent_deliveries()) snapshot.recent_ids.push_back(item.delivery_id);
    if (home_dynamic_snapshot_ && *home_dynamic_snapshot_ == snapshot) return;

    if (window_) {
        GtkWidget* focus = gtk_window_get_focus(GTK_WINDOW(window_));
        while (focus && focus != home_dynamic_box_) {
            auto* id = static_cast<std::string*>(g_object_get_data(G_OBJECT(focus), "focus_delivery_id"));
            if (id) {
                restore_focus_delivery_id_ = *id;
                break;
            }
            focus = gtk_widget_get_parent(focus);
        }
    }

    gtk_container_remove_all_children(home_dynamic_box_);
    home_dynamic_snapshot_ = snapshot;
    if (current_status_.state != delivery::DeliveryState::TooManyDevices &&
        current_status_.state != delivery::DeliveryState::Connecting) {
        refocus_registration_retry_ = false;
    }

    if (current_status_.state == delivery::DeliveryState::Retrying) {
        GtkWidget* banner = gtk_info_bar_new();
        gtk_info_bar_set_message_type(GTK_INFO_BAR(banner), GTK_MESSAGE_WARNING);
        GtkWidget* msg = gtk_label_new(
            current_status_.message.empty()
                ? "Connecting to server..."
                : ("Connecting to server: " + current_status_.message).c_str()
        );
        gtk_label_set_line_wrap(GTK_LABEL(msg), TRUE);
        gtk_container_add(GTK_CONTAINER(gtk_info_bar_get_content_area(GTK_INFO_BAR(banner))), msg);
        gtk_box_pack_start(GTK_BOX(home_dynamic_box_), banner, FALSE, FALSE, 0);
    } else if (current_status_.state == delivery::DeliveryState::TooManyDevices) {
        GtkWidget* banner = gtk_info_bar_new();
        gtk_info_bar_set_message_type(GTK_INFO_BAR(banner), GTK_MESSAGE_ERROR);
        GtkWidget* msg = gtk_label_new(
            "This relay already has the maximum number of devices registered. On a device you no "
            "longer use, choose \"Remove this device\". pux retries on its own, or retry now.");
        gtk_label_set_line_wrap(GTK_LABEL(msg), TRUE);
        gtk_label_set_xalign(GTK_LABEL(msg), 0.0f);
        gtk_container_add(GTK_CONTAINER(gtk_info_bar_get_content_area(GTK_INFO_BAR(banner))), msg);
        GtkWidget* retry_btn = gtk_info_bar_add_button(GTK_INFO_BAR(banner), kRetryRegistrationLabel, GTK_RESPONSE_ACCEPT);
        if (AtkObject* retry_atk = gtk_widget_get_accessible(retry_btn)) {
            atk_object_set_name(retry_atk, kRetryRegistrationLabel);
        }
        g_signal_connect_swapped(retry_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
            self->on_retry_registration_clicked();
        }), this);
        gtk_box_pack_start(GTK_BOX(home_dynamic_box_), banner, FALSE, FALSE, 0);
        if (refocus_registration_retry_) {
            gtk_widget_show_all(banner);
            gtk_widget_grab_focus(retry_btn);
            refocus_registration_retry_ = false;
        }
    } else if (current_status_.state == delivery::DeliveryState::RecordUnknown) {
        GtkWidget* banner = gtk_info_bar_new();
        gtk_info_bar_set_message_type(GTK_INFO_BAR(banner), GTK_MESSAGE_ERROR);
        gtk_container_add(GTK_CONTAINER(gtk_info_bar_get_content_area(GTK_INFO_BAR(banner))),
                          gtk_label_new("This relay was removed from the server."));
        gtk_box_pack_start(GTK_BOX(home_dynamic_box_), banner, FALSE, FALSE, 0);
    }

    if (current_status_.undecryptable_count > 0) {
        GtkWidget* banner = gtk_info_bar_new();
        gtk_info_bar_set_message_type(GTK_INFO_BAR(banner), GTK_MESSAGE_WARNING);
        std::string text = std::to_string(current_status_.undecryptable_count) +
                           " incoming message(s) could not be decrypted.";
        gtk_container_add(GTK_CONTAINER(gtk_info_bar_get_content_area(GTK_INFO_BAR(banner))), gtk_label_new(text.c_str()));
        gtk_box_pack_start(GTK_BOX(home_dynamic_box_), banner, FALSE, FALSE, 0);
    }

    auto held = delivery_service_->held_deliveries();
    if (!held.empty()) {
        GtkWidget* held_frame = gtk_frame_new("Codes that may not have appeared");
        GtkWidget* held_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
        gtk_container_set_border_width(GTK_CONTAINER(held_box), 10);
        GtkWidget* expl = gtk_label_new(
            "pux couldn't confirm these reached you as notifications. They are removed once they do, "
            "or when they expire, and are never saved on this device."
        );
        gtk_label_set_line_wrap(GTK_LABEL(expl), TRUE);
        gtk_box_pack_start(GTK_BOX(held_box), expl, FALSE, FALSE, 0);
        for (const auto& item : held) {
            GtkWidget* row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
            GtkWidget* lbl = gtk_label_new((item.notification.title + "\n" + item.notification.body).c_str());
            gtk_label_set_line_wrap(GTK_LABEL(lbl), TRUE);
            gtk_box_pack_start(GTK_BOX(row), lbl, TRUE, TRUE, 0);
            if (item.notification.code.has_value()) {
                GtkWidget* copy_code_btn = gtk_button_new_from_icon_name("edit-copy-symbolic", GTK_ICON_SIZE_BUTTON);
                std::string acc = "Copy OTP code from " + item.notification.title;
                AtkObject* atk = gtk_widget_get_accessible(copy_code_btn);
                if (atk) atk_object_set_name(atk, acc.c_str());
                g_object_set_data_full(G_OBJECT(copy_code_btn), "otp_code",
                    new std::string(item.notification.code.value()),
                    [](gpointer d) { delete static_cast<std::string*>(d); });
                g_object_set_data_full(G_OBJECT(copy_code_btn), "focus_delivery_id",
                    new std::string(item.delivery_id),
                    [](gpointer d) { delete static_cast<std::string*>(d); });
                g_signal_connect(copy_code_btn, "clicked", G_CALLBACK(+[](GtkButton* btn, gpointer) {
                    auto* c = static_cast<std::string*>(g_object_get_data(G_OBJECT(btn), "otp_code"));
                    if (c) clipboard::SensitiveClipboard::instance().copy(*c);
                }), nullptr);
                gtk_box_pack_end(GTK_BOX(row), copy_code_btn, FALSE, FALSE, 0);
            }
            gtk_box_pack_start(GTK_BOX(held_box), row, FALSE, FALSE, 4);
        }
        gtk_container_add(GTK_CONTAINER(held_frame), held_box);
        gtk_box_pack_start(GTK_BOX(home_dynamic_box_), held_frame, FALSE, FALSE, 0);
    }

    auto recent = delivery_service_->recent_deliveries();
    if (!recent.empty()) {
        GtkWidget* recent_frame = gtk_frame_new("Recent codes");
        GtkWidget* recent_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
        gtk_container_set_border_width(GTK_CONTAINER(recent_box), 10);
        GtkWidget* expl = gtk_label_new(
            "Sent to you as notifications, and kept here in case your desktop didn't show them. "
            "They are removed when they expire, and are never saved on this device."
        );
        gtk_label_set_line_wrap(GTK_LABEL(expl), TRUE);
        gtk_box_pack_start(GTK_BOX(recent_box), expl, FALSE, FALSE, 0);
        for (const auto& item : recent) {
            GtkWidget* row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
            GtkWidget* lbl = gtk_label_new((item.notification.title + "\n" + item.notification.body).c_str());
            gtk_label_set_line_wrap(GTK_LABEL(lbl), TRUE);
            gtk_box_pack_start(GTK_BOX(row), lbl, TRUE, TRUE, 0);
            if (item.notification.code.has_value()) {
                GtkWidget* copy_code_btn = gtk_button_new_from_icon_name("edit-copy-symbolic", GTK_ICON_SIZE_BUTTON);
                std::string acc = "Copy OTP code from " + item.notification.title;
                AtkObject* atk = gtk_widget_get_accessible(copy_code_btn);
                if (atk) atk_object_set_name(atk, acc.c_str());
                g_object_set_data_full(G_OBJECT(copy_code_btn), "otp_code",
                    new std::string(item.notification.code.value()),
                    [](gpointer d) { delete static_cast<std::string*>(d); });
                g_object_set_data_full(G_OBJECT(copy_code_btn), "focus_delivery_id",
                    new std::string(item.delivery_id),
                    [](gpointer d) { delete static_cast<std::string*>(d); });
                g_signal_connect(copy_code_btn, "clicked", G_CALLBACK(+[](GtkButton* btn, gpointer) {
                    auto* c = static_cast<std::string*>(g_object_get_data(G_OBJECT(btn), "otp_code"));
                    if (c) clipboard::SensitiveClipboard::instance().copy(*c);
                }), nullptr);
                gtk_box_pack_end(GTK_BOX(row), copy_code_btn, FALSE, FALSE, 0);
            }
            gtk_box_pack_start(GTK_BOX(recent_box), row, FALSE, FALSE, 4);
        }
        gtk_container_add(GTK_CONTAINER(recent_frame), recent_box);
        gtk_box_pack_start(GTK_BOX(home_dynamic_box_), recent_frame, FALSE, FALSE, 0);
    }

    if (window_ && !restore_focus_delivery_id_.empty()) {
        if (GtkWidget* target = find_focus_widget_by_delivery_id(home_dynamic_box_, restore_focus_delivery_id_)) {
            gtk_widget_grab_focus(target);
        }
        restore_focus_delivery_id_.clear();
    }
}

void AppWindow::build_home_view() {
    view_mode_ = ViewMode::Home;
    gtk_header_bar_set_title(header_bar_, "pux");
    gtk_header_bar_set_subtitle(header_bar_, record_store_->server_url().c_str());

    GtkWidget* health_btn = gtk_button_new_from_icon_name("network-transmit-receive-symbolic", GTK_ICON_SIZE_BUTTON);
    gtk_widget_set_tooltip_text(health_btn, "Check server health");
    AtkObject* atk_health = gtk_widget_get_accessible(health_btn);
    if (atk_health) atk_object_set_name(atk_health, "Check server health");
    g_signal_connect_swapped(health_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
        self->on_refresh_health_clicked();
    }), this);
    gtk_header_bar_pack_end(header_bar_, health_btn);

    home_dynamic_box_ = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_box_pack_start(GTK_BOX(content_box_), home_dynamic_box_, FALSE, FALSE, 0);
    rebuild_home_dynamic_sections();

    // Status Frame
    GtkWidget* status_frame = gtk_frame_new("Relay active");
    GtkWidget* status_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_container_set_border_width(GTK_CONTAINER(status_box), 16);

    GtkWidget* inbox_title = gtk_label_new("Forward verification emails to:");
    gtk_label_set_line_wrap(GTK_LABEL(inbox_title), TRUE);
    gtk_label_set_line_wrap_mode(GTK_LABEL(inbox_title), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(inbox_title), 0.0f);
    gtk_box_pack_start(GTK_BOX(status_box), inbox_title, FALSE, FALSE, 0);

    auto inbox_opt = record_store_->inbox();
    std::string inbox_str = inbox_opt.value_or("No inbox address assigned");
    GtkWidget* inbox_label = gtk_label_new(inbox_str.c_str());
    gtk_label_set_selectable(GTK_LABEL(inbox_label), TRUE);
    gtk_label_set_line_wrap(GTK_LABEL(inbox_label), TRUE);
    gtk_label_set_line_wrap_mode(GTK_LABEL(inbox_label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(inbox_label), 0.0f);
    gtk_box_pack_start(GTK_BOX(status_box), inbox_label, FALSE, FALSE, 0);

    GtkWidget* btn_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget* copy_btn = gtk_button_new_with_label("Copy address");
    g_signal_connect_swapped(copy_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
        self->on_copy_inbox_clicked();
    }), this);
    gtk_box_pack_start(GTK_BOX(btn_row), copy_btn, FALSE, FALSE, 0);

    GtkWidget* help_btn = gtk_button_new_with_label("How to set up forwarding");
    g_signal_connect_swapped(help_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
        self->on_how_to_forward_clicked();
    }), this);
    gtk_box_pack_start(GTK_BOX(btn_row), help_btn, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(status_box), btn_row, FALSE, FALSE, 4);

    gtk_container_add(GTK_CONTAINER(status_frame), status_box);
    gtk_box_pack_start(GTK_BOX(content_box_), status_frame, FALSE, FALSE, 0);

    // Add device / Export QR section
    GtkWidget* add_device_frame = gtk_frame_new("Add device");
    GtkWidget* add_device_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(add_device_box), 12);

    GtkWidget* toggle_btn = gtk_button_new_with_label(show_qr_ ? "Hide QR" : "Show QR");
    g_signal_connect_swapped(toggle_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
        self->on_toggle_qr_clicked();
    }), this);
    gtk_box_pack_start(GTK_BOX(add_device_box), toggle_btn, FALSE, FALSE, 0);

    if (show_qr_) {
        GtkWidget* qr_section = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);

        GtkWidget* warning = gtk_label_new(
            "Scan this QR on another phone, or copy the enrollment JSON and "
            "paste it into the desktop app. Both contain your private key: "
            "only use them with devices you trust."
        );
        gtk_label_set_line_wrap(GTK_LABEL(warning), TRUE);
        gtk_label_set_line_wrap_mode(GTK_LABEL(warning), PANGO_WRAP_WORD_CHAR);
        gtk_label_set_xalign(GTK_LABEL(warning), 0.0f);
        gtk_box_pack_start(GTK_BOX(qr_section), warning, FALSE, FALSE, 0);

        // Generate and render visual QR Code
        auto payload = record_store_->enrollment_payload();
        std::string json_str = payload.dump();
        try {
            auto* qr = new qrcodegen::QrCode(
                qrcodegen::QrCode::encodeText(json_str.c_str(), qrcodegen::QrCode::Ecc::LOW)
            );

            GtkWidget* qr_area = gtk_drawing_area_new();
            gtk_widget_set_tooltip_text(qr_area, "Enrollment QR code");
            AtkObject* atk_qr = gtk_widget_get_accessible(qr_area);
            if (atk_qr) atk_object_set_name(atk_qr, "Enrollment QR code");
            gtk_widget_set_size_request(qr_area, 260, 260);
            g_object_set_data_full(G_OBJECT(qr_area), "qr_data", qr, [](gpointer d) {
                delete static_cast<qrcodegen::QrCode*>(d);
            });

            g_signal_connect(qr_area, "draw", G_CALLBACK(+[](GtkWidget* widget, cairo_t* cr, gpointer) -> gboolean {
                auto* qr_code = static_cast<qrcodegen::QrCode*>(g_object_get_data(G_OBJECT(widget), "qr_data"));
                if (!qr_code) return FALSE;

                int width = gtk_widget_get_allocated_width(widget);
                int height = gtk_widget_get_allocated_height(widget);
                int qr_size = qr_code->getSize();
                int border = 4;
                int total_modules = qr_size + border * 2;
                double scale = std::min(width, height) / static_cast<double>(total_modules);
                double offset_x = (width - total_modules * scale) / 2.0;
                double offset_y = (height - total_modules * scale) / 2.0;

                // Background
                cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
                cairo_rectangle(cr, offset_x, offset_y, total_modules * scale, total_modules * scale);
                cairo_fill(cr);

                // Black modules
                cairo_set_source_rgb(cr, 0.0, 0.0, 0.0);
                for (int y = 0; y < qr_size; y++) {
                    for (int x = 0; x < qr_size; x++) {
                        if (qr_code->getModule(x, y)) {
                            cairo_rectangle(
                                cr,
                                offset_x + (x + border) * scale,
                                offset_y + (y + border) * scale,
                                scale,
                                scale
                            );
                            cairo_fill(cr);
                        }
                    }
                }
                return FALSE;
            }), nullptr);

            gtk_box_pack_start(GTK_BOX(qr_section), qr_area, FALSE, FALSE, 8);
        } catch (const std::exception& e) {
            GtkWidget* qr_err = gtk_label_new("Could not generate visual QR code");
            gtk_box_pack_start(GTK_BOX(qr_section), qr_err, FALSE, FALSE, 0);
        }

        GtkWidget* copy_json_btn = gtk_button_new_with_label("Copy enrollment JSON");
        g_signal_connect_swapped(copy_json_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
            self->on_copy_enrollment_json_clicked();
        }), this);
        gtk_box_pack_start(GTK_BOX(qr_section), copy_json_btn, FALSE, FALSE, 0);

        gtk_box_pack_start(GTK_BOX(add_device_box), qr_section, FALSE, FALSE, 8);
    }

    gtk_container_add(GTK_CONTAINER(add_device_frame), add_device_box);
    gtk_box_pack_start(GTK_BOX(content_box_), add_device_frame, FALSE, FALSE, 0);

    // Advanced / Actions section
    GtkWidget* actions_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);

    GtkWidget* test_btn = gtk_button_new_with_label("Send test code");
    g_signal_connect_swapped(test_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
        self->on_send_test_code_clicked();
    }), this);
    gtk_box_pack_start(GTK_BOX(actions_box), test_btn, FALSE, FALSE, 0);

    GtkWidget* remove_btn = gtk_button_new_with_label("Remove this device");
    g_signal_connect_swapped(remove_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
        self->on_remove_device_clicked();
    }), this);
    gtk_box_pack_start(GTK_BOX(actions_box), remove_btn, FALSE, FALSE, 0);

    GtkWidget* delete_btn = gtk_button_new_with_label("Delete relay everywhere");
    g_signal_connect_swapped(delete_btn, "clicked", G_CALLBACK(+[](AppWindow* self) {
        self->on_delete_relay_clicked();
    }), this);
    gtk_box_pack_start(GTK_BOX(actions_box), delete_btn, FALSE, FALSE, 0);

    gtk_box_pack_start(GTK_BOX(content_box_), actions_box, FALSE, FALSE, 12);
}

void AppWindow::on_import_clicked() {
    if (!import_text_view_ || !import_error_label_) return;

    GtkTextBuffer* buf = gtk_text_view_get_buffer(import_text_view_);
    GtkTextIter start, end;
    gtk_text_buffer_get_start_iter(buf, &start);
    gtk_text_buffer_get_end_iter(buf, &end);
    gchar* raw_text = gtk_text_buffer_get_text(buf, &start, &end, FALSE);
    std::string text(raw_text ? raw_text : "");
    g_free(raw_text);

    try {
        nlohmann::json payload = record_store_->parse_qr(text);
        std::string server = record_store_->enrollment_server(payload);

        if (!confirm_server_dialog(server)) {
            return;
        }

        *enrollment_alive_ = false;
        enrollment_alive_ = std::make_shared<std::atomic<bool>>(true);
        if (storage_) {
            storage_loading_ = true;
            refresh_views();
            storage_->submit([payload](storage::RecordStore& store) {
                store.save_enrollment(payload);
                store.desktop_device_id();
            }, enrollment_alive_, [this, alive = alive_](const std::string& error) {
                if (!alive->load()) return;
                storage_loading_ = false;
                storage_error_ = error;
                refresh_views();
            });
            return;
        }
        record_store_->save_enrollment(payload);
        refresh_views();
    } catch (const std::exception& e) {
        gtk_label_set_text(import_error_label_, e.what());
    }
}

bool AppWindow::confirm_server_dialog(const std::string& server_url) {
    GtkWidget* dialog = gtk_message_dialog_new(
        window_,
        GTK_DIALOG_MODAL,
        GTK_MESSAGE_QUESTION,
        GTK_BUTTONS_OK_CANCEL,
        "Connect to this server?"
    );
    std::string secondary = "This enrollment uses the pux server:\n" + server_url +
                           "\n\nOnly continue if you recognise this server.";
    gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog), "%s", secondary.c_str());
    gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_OK);
    GtkWidget* ok = gtk_dialog_get_widget_for_response(GTK_DIALOG(dialog), GTK_RESPONSE_OK);
    if (ok) gtk_widget_grab_default(ok);

    gint res = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    return res == GTK_RESPONSE_OK;
}

bool AppWindow::confirm_delete_relay_dialog() {
    GtkWidget* dialog = gtk_dialog_new_with_buttons(
        "Delete relay everywhere?",
        window_,
        GTK_DIALOG_MODAL,
        "_Cancel", GTK_RESPONSE_CANCEL,
        "Delete everywhere", GTK_RESPONSE_OK,
        nullptr
    );
    GtkWidget* content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(box), 12);
    GtkWidget* body = gtk_label_new(
        "This deletes the relay from the server. Every device on it stops receiving codes, "
        "the inbox address stops working and pending codes are discarded. This cannot be undone."
    );
    gtk_label_set_line_wrap(GTK_LABEL(body), TRUE);
    gtk_label_set_xalign(GTK_LABEL(body), 0.0f);
    gtk_box_pack_start(GTK_BOX(box), body, FALSE, FALSE, 0);
    GtkWidget* prompt = gtk_label_new("Type \"delete\" to confirm.");
    gtk_label_set_xalign(GTK_LABEL(prompt), 0.0f);
    gtk_box_pack_start(GTK_BOX(box), prompt, FALSE, FALSE, 8);
    GtkWidget* entry = gtk_entry_new();
    gtk_entry_set_activates_default(GTK_ENTRY(entry), FALSE);
    gtk_box_pack_start(GTK_BOX(box), entry, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(content), box, TRUE, TRUE, 0);
    GtkWidget* delete_btn = gtk_dialog_get_widget_for_response(GTK_DIALOG(dialog), GTK_RESPONSE_OK);
    gtk_widget_set_sensitive(delete_btn, FALSE);
    GtkStyleContext* del_ctx = gtk_widget_get_style_context(delete_btn);
    if (del_ctx) gtk_style_context_add_class(del_ctx, "destructive-action");
    g_signal_connect(entry, "changed", G_CALLBACK(+[](GtkEntry* e, GtkWidget* btn) {
        const gchar* t = gtk_entry_get_text(e);
        bool ok = t && g_ascii_strcasecmp(t, "delete") == 0;
        gtk_widget_set_sensitive(btn, ok ? TRUE : FALSE);
    }), delete_btn);
    gtk_widget_show_all(dialog);
    const gint res = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    return res == GTK_RESPONSE_OK;
}

bool AppWindow::confirm_copy_json_dialog() {
    GtkWidget* dialog = gtk_message_dialog_new(
        window_,
        GTK_DIALOG_MODAL,
        GTK_MESSAGE_WARNING,
        GTK_BUTTONS_OK_CANCEL,
        "Copy enrollment JSON?"
    );
    gtk_message_dialog_format_secondary_text(
        GTK_MESSAGE_DIALOG(dialog),
        "This contains your private key and relay ID. Anyone who has it can read your OTP codes. "
        "Paste it only into your own desktop app, then clear your clipboard."
    );
    gint res = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    return res == GTK_RESPONSE_OK;
}

void AppWindow::on_copy_inbox_clicked() {
    auto inb = record_store_->inbox();
    if (inb.has_value() && !inb->empty()) {
        clipboard::SensitiveClipboard::instance().copy(inb.value());
        show_info_dialog(window_, "Copied", "Inbox address copied to clipboard.");
    }
}

void AppWindow::on_how_to_forward_clicked() {
    std::string help_text =
        "In Gmail or Google Workspace:\n\n"
        "1. Open Settings -> See all settings -> Forwarding and POP/IMAP.\n"
        "2. Click 'Add a forwarding address' and paste your pux inbox address.\n"
        "3. Google will send a confirmation code to pux. Look for the notification or find it under 'Codes that may not have appeared'.\n"
        "4. Click the confirmation link or enter the verification code in Gmail settings.\n"
        "5. Under 'Filters and Blocked Addresses', create a filter for verification emails and forward them to your pux address.";
    show_info_dialog(window_, "Set up forwarding", help_text);
}

void AppWindow::on_send_test_code_clicked() {
    auto rid = record_store_->record_id();
    if (!rid.has_value()) return;

    std::string server = record_store_->server_url();
    std::string record_id = rid.value();
    auto api_client = api_client_;

    std::thread([this, server, record_id, api_client, alive = alive_, enrollment = enrollment_alive_]() {
        try {
            auto test = api_client->send_test_code(server, record_id);
            std::string msg = "Test code sent: " + test.otp + "\nSent to " + std::to_string(test.devices) + " device(s).\n"
                              "Look for a notification from pux.";
            post_to_main_thread(alive, [this, msg, enrollment]() {
                if (!enrollment->load()) return;
                if (window_) {
                    show_info_dialog(window_, "Test code sent", msg);
                }
            });
        } catch (const std::exception& e) {
            std::string err = e.what();
            post_to_main_thread(alive, [this, err, enrollment]() {
                if (!enrollment->load()) return;
                if (window_) {
                    show_info_dialog(window_, "Could not send test code", err);
                }
            });
        }
    }).detach();
}

void AppWindow::on_toggle_qr_clicked() {
    show_qr_ = !show_qr_;
    refresh_views();
}

void AppWindow::on_copy_enrollment_json_clicked() {
    if (!confirm_copy_json_dialog()) return;

    auto payload = record_store_->enrollment_payload();
    std::string json_str = payload.dump();
    clipboard::SensitiveClipboard::instance().copy(json_str);
    show_info_dialog(window_, "Copied", "Enrollment JSON copied. It is cleared from the clipboard in a minute.");
}

void AppWindow::remove_with(const std::string&, const std::string&, const std::string& action) {
    if (!removal_) return;
    auto rid = record_store_->record_id();
    auto did = record_store_->device_id();
    if (!rid) { show_info_dialog(window_, "Cannot remove relay", "The relay ID is unavailable."); return; }
    *enrollment_alive_ = false;
    enrollment_alive_ = std::make_shared<std::atomic<bool>>(true);
    removal_->begin(action, *rid, did.value_or(""));
}

void AppWindow::on_remove_device_clicked() {
    GtkWidget* dialog = gtk_dialog_new_with_buttons(
        "Remove this device?",
        window_,
        GTK_DIALOG_MODAL,
        "_Cancel", GTK_RESPONSE_CANCEL,
        "_Remove", GTK_RESPONSE_OK,
        nullptr
    );
    GtkWidget* content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    GtkWidget* body = gtk_label_new(
        "This device stops receiving codes and its keys are deleted from it. "
        "Other devices on this relay keep working. To use pux here again you "
        "will need to create or import a relay."
    );
    gtk_label_set_line_wrap(GTK_LABEL(body), TRUE);
    gtk_container_set_border_width(GTK_CONTAINER(body), 12);
    gtk_box_pack_start(GTK_BOX(content), body, TRUE, TRUE, 0);
    GtkWidget* remove_btn = gtk_dialog_get_widget_for_response(GTK_DIALOG(dialog), GTK_RESPONSE_OK);
    GtkStyleContext* ctx = gtk_widget_get_style_context(remove_btn);
    if (ctx) gtk_style_context_add_class(ctx, "destructive-action");
    gtk_widget_show_all(dialog);
    const gint res = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    if (res != GTK_RESPONSE_OK) return;

    remove_with(
        "Couldn't remove this device from the server",
        "If you forget it locally, the server keeps this registration until it expires, which can take up to 2 years.",
        "device"
    );
}

void AppWindow::on_delete_relay_clicked() {
    if (!confirm_delete_relay_dialog()) return;

    remove_with(
        "Couldn't delete the relay",
        "If you forget it locally, the relay keeps running on the server and your other devices keep receiving codes.",
        "relay"
    );
}

void AppWindow::on_retry_registration_clicked() {
    if (!alive_->load() || !window_) return;
    // The banner is replaced while the attempt runs; put focus back on the new
    // Retry button if it is rejected again, so keyboard and screen-reader users
    // keep their place.
    refocus_registration_retry_ = true;
    if (!delivery_service_->retry_registration()) refocus_registration_retry_ = false;
}

void AppWindow::on_refresh_health_clicked() {
    std::string server = record_store_->server_url();
    auto api_client = api_client_;
    std::thread([this, server, api_client, alive = alive_, enrollment = enrollment_alive_]() {
        auto health = api_client->check_health(server);
        post_to_main_thread(alive, [this, health, enrollment]() {
            if (!enrollment->load()) return;
            if (!alive_->load() || !window_) return;
            std::string msg;
            if (health.state == api::ServerHealthState::Reachable) {
                msg = "Server is reachable.";
            } else {
                msg = "Server unreachable / error: " + health.reason;
            }
            show_info_dialog(window_, "Server Health", msg);
        });
    }).detach();
}

} // namespace ui
} // namespace pux
