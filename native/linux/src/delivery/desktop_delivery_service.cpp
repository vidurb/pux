#include "desktop_delivery_service.hpp"
#include "../crypto/crypto.hpp"
#include "../storage/registration_outcome.hpp"
#include <glib.h>
#include <iostream>
#include <algorithm>
#include <cmath>
#include <random>
#include <thread>

namespace pux {
namespace delivery {

namespace {

struct MainThreadTask {
    std::shared_ptr<std::atomic<bool>> alive;
    std::function<void()> fn;
};

struct RegistrationGuard {
    std::shared_ptr<RegistrationActivity> activity;
    ~RegistrationGuard() { activity->end(); }
};

gboolean main_thread_dispatcher(gpointer user_data) {
    auto* task = static_cast<MainThreadTask*>(user_data);
    if (task) {
        if (task->alive && task->alive->load()) {
            try { task->fn(); }
            catch (const std::exception& e) { std::cerr << "Delivery callback failed: " << e.what() << "\n"; }
            catch (...) { std::cerr << "Delivery callback failed\n"; }
        }
        delete task;
    }
    return G_SOURCE_REMOVE;
}

void dispatch_to_main(const std::shared_ptr<std::atomic<bool>>& alive, std::function<void()> fn) {
    g_idle_add(main_thread_dispatcher, new MainThreadTask{alive, std::move(fn)});
}

gboolean recheck_timer_cb(gpointer user_data) {
    auto* self = static_cast<DesktopDeliveryService*>(user_data);
    try {
        self->recheck_held();
    } catch (const std::exception& e) {
        std::cerr << "Warning in recheck_held timer: " << e.what() << "\n";
    } catch (...) {}
    return G_SOURCE_CONTINUE;
}

gboolean registration_timer_cb(gpointer user_data) {
    auto* self = static_cast<DesktopDeliveryService*>(user_data);
    try {
        self->register_device_async();
    } catch (const api::RecordNotFoundException&) {
        self->update_status(DeliveryState::RecordUnknown);
    } catch (const api::TooManyDevicesException&) {
        self->update_status(DeliveryState::TooManyDevices);
    } catch (const std::exception& e) {
        std::cerr << "Warning in periodic device registration: " << e.what() << "\n";
    } catch (...) {}
    return G_SOURCE_CONTINUE;
}

gboolean reconnect_timer_cb(gpointer user_data) {
    auto* self = static_cast<DesktopDeliveryService*>(user_data);
    self->clear_reconnect_timer_id();
    try {
        if (!self->is_stopped()) {
            self->reconnect_socket();
        }
    } catch (const std::exception& e) {
        std::cerr << "Warning in reconnect timer: " << e.what() << "\n";
    } catch (...) {}
    return G_SOURCE_REMOVE;
}

gboolean registration_retry_timer_cb(gpointer user_data) {
    auto* self = static_cast<DesktopDeliveryService*>(user_data);
    self->clear_registration_retry_timer_id();
    try {
        if (!self->is_stopped()) {
            self->register_device_async();
        }
    } catch (const std::exception& e) {
        std::cerr << "Warning in registration retry timer: " << e.what() << "\n";
    } catch (...) {}
    return G_SOURCE_REMOVE;
}

gboolean periodic_poll_timer_cb(gpointer user_data) {
    auto* self = static_cast<DesktopDeliveryService*>(user_data);
    try {
        if (!self->is_stopped()) {
            self->poll_pending_async();
        }
    } catch (const std::exception& e) {
        std::cerr << "Warning in periodic poll timer: " << e.what() << "\n";
    } catch (...) {}
    return G_SOURCE_CONTINUE;
}

} // namespace

std::chrono::milliseconds reconnect_backoff_delay(int attempt, uint32_t jitter_ms) {
    constexpr auto kMin = std::chrono::seconds(2);
    constexpr auto kMax = std::chrono::minutes(5);
    const int capped_attempt = std::min(attempt, 16);
    const auto kMinMs = std::chrono::duration_cast<std::chrono::milliseconds>(kMin).count();
    const auto kMaxMs = std::chrono::duration_cast<std::chrono::milliseconds>(kMax).count();
    const double base = static_cast<double>(kMinMs) * std::pow(2.0, capped_attempt);
    const auto capped = static_cast<int64_t>(std::min(base, static_cast<double>(kMaxMs)));
    uint32_t jitter = jitter_ms;
    if (jitter == 0) {
        static thread_local std::mt19937 rng{std::random_device{}()};
        jitter = static_cast<uint32_t>(rng() % (static_cast<uint32_t>(capped / 4) + 1));
    }
    const int64_t total = std::min<int64_t>(capped + jitter, kMaxMs);
    return std::chrono::milliseconds(total);
}

std::chrono::milliseconds registration_retry_delay(
    int attempt, std::chrono::milliseconds base, std::chrono::milliseconds max) {
    if (base.count() <= 0) base = std::chrono::milliseconds(1);
    if (max < base) max = base;
    const int capped_attempt = std::min(std::max(attempt, 0), 30);
    const double scaled = static_cast<double>(base.count()) * std::pow(2.0, capped_attempt);
    const auto ms = static_cast<int64_t>(std::min(scaled, static_cast<double>(max.count())));
    return std::chrono::milliseconds(ms);
}

DesktopDeliveryService::DesktopDeliveryService(
    std::shared_ptr<storage::RecordStore> record_store,
    std::shared_ptr<api::ApiClient> api_client,
    std::shared_ptr<notifications::NotificationService> notification_service,
    DeliveryTiming timing,
    std::shared_ptr<storage::StorageCoordinator> storage
) : record_store_(std::move(record_store)),
    api_client_(std::move(api_client)),
    notification_service_(std::move(notification_service)), timing_(timing), storage_(std::move(storage)),
    alive_(std::make_shared<std::atomic<bool>>(true)) {}

DesktopDeliveryService::~DesktopDeliveryService() {
    *alive_ = false;
    status_cb_ = nullptr;
    held_cb_ = nullptr;
    stop();
}

std::vector<HeldDelivery> DesktopDeliveryService::held_deliveries() const {
    std::vector<HeldDelivery> res;
    for (const auto& [_, d] : holding_) {
        res.push_back(d);
    }
    return res;
}

std::vector<HeldDelivery> DesktopDeliveryService::recent_deliveries() const {
    std::vector<HeldDelivery> res;
    for (const auto& [_, d] : recent_) {
        res.push_back(d);
    }
    return res;
}

void DesktopDeliveryService::update_status(DeliveryState state, const std::string& message) {
    status_.state = state;
    status_.message = message;
    status_.undecryptable_count = undecryptable_.size();
    if (status_cb_) {
        status_cb_(status_);
    }
}

void DesktopDeliveryService::ensure_recheck_timer() {
    if (holding_.empty() && recent_.empty()) {
        if (recheck_timer_id_ != 0) {
            g_source_remove(recheck_timer_id_);
            recheck_timer_id_ = 0;
        }
    } else {
        if (recheck_timer_id_ == 0) {
            recheck_timer_id_ = g_timeout_add(
                static_cast<guint>(timing_.recheck.count()),
                recheck_timer_cb,
                this
            );
        }
    }
}

void DesktopDeliveryService::ensure_periodic_poll_timer() {
    if (periodic_poll_timer_id_ == 0) {
        periodic_poll_timer_id_ = g_timeout_add(
            static_cast<guint>(timing_.poll.count()),
            periodic_poll_timer_cb,
            this
        );
    }
}

void DesktopDeliveryService::publish_held() {
    if (held_cb_) {
        held_cb_(held_deliveries(), recent_deliveries());
    }
    ensure_recheck_timer();
}

void DesktopDeliveryService::cancel_timers() {
    if (recheck_timer_id_ != 0) {
        g_source_remove(recheck_timer_id_);
        recheck_timer_id_ = 0;
    }
    if (registration_timer_id_ != 0) {
        g_source_remove(registration_timer_id_);
        registration_timer_id_ = 0;
    }
    if (reconnect_timer_id_ != 0) {
        g_source_remove(reconnect_timer_id_);
        reconnect_timer_id_ = 0;
    }
    if (periodic_poll_timer_id_ != 0) {
        g_source_remove(periodic_poll_timer_id_);
        periodic_poll_timer_id_ = 0;
    }
    cancel_registration_retry();
}

void DesktopDeliveryService::start() {
    if (ws_client_) ws_client_->disconnect();
    *alive_ = false;
    alive_ = std::make_shared<std::atomic<bool>>(true);
    cancel_timers();
    stopped_ = true;
    poll_in_flight_ = false;
    registration_in_flight_ = false;
    registered_ = false;
    in_flight_.clear();
    reconnect_attempt_ = 0;
    registration_retry_attempt_ = 0;
    if (!record_store_->is_enrolled()) {
        update_status(DeliveryState::Idle);
        return;
    }

    // Snapshot enrollment on the main thread; workers only perform network I/O.
    auto server = record_store_->server_url();
    auto rid = record_store_->record_id();
    auto token = record_store_->desktop_device_id();
    stopped_ = false;
    update_status(DeliveryState::Connecting);
    ensure_periodic_poll_timer();
    ensure_recheck_timer();

    // 12-hour re-registration timer
    registration_timer_id_ = g_timeout_add_seconds(
        static_cast<guint>(std::chrono::duration_cast<std::chrono::seconds>(kRegistrationInterval).count()),
        registration_timer_cb,
        this
    );

    auto activity = registration_activity_;
    activity->begin();
    registration_in_flight_ = true;
    auto self = shared_from_this();
    std::thread([self, alive = alive_, api_client = api_client_, server, rid, token, activity]() {
        RegistrationGuard guard{activity};
        try {
            if (!rid.has_value()) return;

            std::string registered_device = api_client->register_device(
                    server,
                    rid.value(),
                    token,
                    "desktop",
                    ""
                );
            activity->remember(*rid, registered_device);

            dispatch_to_main(alive, [self, registered_device]() {
                self->registration_in_flight_ = false;
                if (self->stopped_) return;
                self->persist_registration(registered_device, true);
            });
        } catch (const api::RecordNotFoundException&) {
            dispatch_to_main(alive, [self]() { self->registration_in_flight_ = false; self->update_status(DeliveryState::RecordUnknown); });
        } catch (const api::TooManyDevicesException&) {
            dispatch_to_main(alive, [self]() { self->registration_in_flight_ = false; self->handle_device_limit_rejection(); });
        } catch (const std::exception& e) {
            std::string err = e.what();
            self->mark_registration_outcome_uncertain_async(nullptr);
            dispatch_to_main(alive, [self, err]() {
                self->registration_in_flight_ = false;
                self->schedule_reconnect(err);
            });
        }
    }).detach();
}

void DesktopDeliveryService::reconnect_socket() {
    if (stopped_) return;
    update_status(DeliveryState::Connecting);
    if (!registered_) register_device_async();
    else connect_websocket();
}

void DesktopDeliveryService::suspend() {
    if (registration_in_flight_ || registration_activity_->has_active()) {
        mark_registration_outcome_uncertain_async(nullptr);
    }
    *alive_ = false;
    if (socket_alive_) *socket_alive_ = false;
    stopped_ = true;
    poll_in_flight_ = false;
    registration_in_flight_ = false;
    registered_ = false;
    cancel_timers();

    if (ws_client_) {
        ws_client_->disconnect();
    }
    update_status(DeliveryState::Idle);
}

bool DesktopDeliveryService::registration_outcome_uncertain() const {
    return storage::registration_outcome_uncertain(*record_store_);
}

void DesktopDeliveryService::mark_registration_outcome_uncertain_async(storage::StorageCoordinator::Completion completion) {
    if (storage_) {
        storage_->submit_durable([](storage::RecordStore& store) { storage::mark_registration_outcome_uncertain(store); },
            std::move(completion));
        return;
    }
    storage::mark_registration_outcome_uncertain(*record_store_);
    if (completion) {
        dispatch_to_main(alive_, [completion]() { completion(""); });
    }
}

void DesktopDeliveryService::clear_registration_outcome_uncertain_async(storage::StorageCoordinator::Completion completion) {
    if (storage_) {
        storage_->submit_durable([](storage::RecordStore& store) { storage::clear_registration_outcome_uncertain(store); },
            std::move(completion));
        return;
    }
    storage::clear_registration_outcome_uncertain(*record_store_);
    if (completion) {
        dispatch_to_main(alive_, [completion]() { completion(""); });
    }
}

void DesktopDeliveryService::prepare_for_device_removal(RegistrationFenceCallback continuation) {
    if (!continuation) return;
    auto self = shared_from_this();
    auto deliver = [self, continuation = std::move(continuation)](const std::string& error) {
        dispatch_to_main(self->alive_, [self, continuation, error]() {
            if (!self->alive_->load()) return;
            continuation(error);
        });
    };
    if (!registration_in_flight_ && !registration_activity_->has_active()) {
        deliver("");
        return;
    }
    mark_registration_outcome_uncertain_async(deliver);
}

void DesktopDeliveryService::stop() {
    suspend();
    notification_service_->clear();
    holding_.clear();
    recent_.clear();
    in_flight_.clear();
    finished_.clear();
    undecryptable_.clear();

    publish_held();
}

void DesktopDeliveryService::register_device() {
    auto record_id = record_store_->record_id();
    if (!record_id.has_value() || record_id->empty()) return;

    std::string token = record_store_->desktop_device_id();
    std::string dev_id = api_client_->register_device(
        record_store_->server_url(),
        record_id.value(),
        token,
        "desktop",
        ""
    );
    record_store_->save_device_id(dev_id);
}

void DesktopDeliveryService::register_device_async() {
    if (stopped_ || registration_in_flight_) return;
    auto record_id = record_store_->record_id();
    if (!record_id || record_id->empty()) return;
    auto server = record_store_->server_url();
    auto token = record_store_->desktop_device_id();
    auto api = api_client_;
    auto alive = alive_;
    auto activity = registration_activity_;
    activity->begin();
    registration_in_flight_ = true;
    auto self = shared_from_this();
    std::thread([self, alive, api, server, record_id, token, activity]() {
        RegistrationGuard guard{activity};
        try {
            auto id = api->register_device(server, *record_id, token, "desktop", "");
            activity->remember(*record_id, id);
            dispatch_to_main(alive, [self, id]() {
                self->registration_in_flight_ = false;
                bool needs_connection = !self->registered_;
                self->persist_registration(id, needs_connection);
            });
        } catch (const api::RecordNotFoundException&) {
            dispatch_to_main(alive, [self]() { self->registration_in_flight_ = false; self->update_status(DeliveryState::RecordUnknown); });
        } catch (const api::TooManyDevicesException&) {
            dispatch_to_main(alive, [self]() { self->registration_in_flight_ = false; self->handle_device_limit_rejection(); });
        } catch (const std::exception& e) {
            auto error = std::string(e.what());
            self->mark_registration_outcome_uncertain_async(nullptr);
            dispatch_to_main(alive, [self, error]() {
                self->registration_in_flight_ = false;
                self->schedule_reconnect(error);
            });
        }
    }).detach();
}

void DesktopDeliveryService::handle_device_limit_rejection() {
    if (stopped_) return;
    // The server did not accept this registration, so this client is not
    // registered: a later success must also reconnect the socket and poll.
    registered_ = false;
    update_status(DeliveryState::TooManyDevices);
    schedule_registration_retry();
}

void DesktopDeliveryService::schedule_registration_retry() {
    if (stopped_) return;
    cancel_registration_retry();
    const auto delay = registration_retry_delay(
        registration_retry_attempt_++, timing_.registration_retry, timing_.registration_retry_max);
    registration_retry_timer_id_ = g_timeout_add(
        static_cast<guint>(delay.count()),
        registration_retry_timer_cb,
        this
    );
}

void DesktopDeliveryService::cancel_registration_retry() {
    if (registration_retry_timer_id_ != 0) {
        g_source_remove(registration_retry_timer_id_);
        registration_retry_timer_id_ = 0;
    }
}

bool DesktopDeliveryService::retry_registration() {
    if (stopped_ || registration_in_flight_ || status_.state != DeliveryState::TooManyDevices) return false;
    cancel_registration_retry();
    registration_retry_attempt_ = 0;
    update_status(DeliveryState::Connecting);
    register_device_async();
    return true;
}

void DesktopDeliveryService::persist_registration(const std::string& id, bool connect_after) {
    auto self = shared_from_this();
    auto after_persisted = [self, connect_after](const std::string& error) {
        if (!error.empty()) { self->schedule_reconnect(error); return; }
        self->registered_ = true;
        self->registration_retry_attempt_ = 0;
        self->cancel_registration_retry();
        // The server accepted this device, so stop showing the device-limit error
        // while the socket connects instead of leaving it up until that resolves.
        if (self->status_.state == DeliveryState::TooManyDevices) self->update_status(DeliveryState::Connecting);
        auto connect_if_needed = [self, connect_after]() {
            if (connect_after) { self->poll_pending_async(); self->connect_websocket(); }
        };
        if (self->registration_outcome_uncertain()) {
            connect_if_needed();
            return;
        }
        self->clear_registration_outcome_uncertain_async([self, connect_if_needed](const std::string& clear_error) {
            if (!clear_error.empty()) {
                std::cerr << "Clearing registration uncertainty failed: " << clear_error << "\n";
            }
            connect_if_needed();
        });
    };
    if (!storage_) {
        record_store_->save_device_id(id);
        after_persisted("");
        return;
    }
    auto record = record_store_->record_id();
    storage_->submit([record, id](storage::RecordStore& backend) {
        if (!record || backend.record_id() != record) throw storage::StorageException("Enrollment changed during registration");
        backend.save_device_id(id);
    }, alive_, after_persisted);
}

void DesktopDeliveryService::poll_pending_async() {
    if (stopped_ || poll_in_flight_) return;
    auto server = record_store_->server_url();
    auto rid = record_store_->record_id();
    if (!rid || rid->empty()) return;
    std::set<std::string> held_before;
    for (const auto& [id, _] : holding_) held_before.insert(id);
    poll_in_flight_ = true;
    auto self = shared_from_this();
    std::thread([self, alive = alive_, api_client = api_client_, server, rid, held_before]() {
        try {
            auto pending = api_client->list_pending_deliveries(server, rid.value());
            dispatch_to_main(alive, [self, pending, held_before]() {
                self->poll_in_flight_ = false;
                if (self->stopped_) return;
                if (pending.size() < api::ApiClient::kPendingPageSize) {
                    auto missing = held_before;
                    for (const auto& env : pending) missing.erase(env.delivery_id);
                    self->forget_held(std::vector<std::string>(missing.begin(), missing.end()));
                }
                for (const auto& env : pending) {
                    self->handle_delivery(env.delivery_id, env.envelope);
                }
            });
        } catch (const api::RecordNotFoundException&) {
            dispatch_to_main(alive, [self]() { self->poll_in_flight_ = false; self->update_status(DeliveryState::RecordUnknown); });
        } catch (const std::exception& e) {
            dispatch_to_main(alive, [self]() { self->poll_in_flight_ = false; });
        }
    }).detach();
}

void DesktopDeliveryService::poll_pending() {
    if (stopped_) return;

    auto record_id = record_store_->record_id();
    if (!record_id.has_value() || record_id->empty()) return;

    std::set<std::string> held_before;
    for (const auto& [id, _] : holding_) {
        held_before.insert(id);
    }

    auto pending = api_client_->list_pending_deliveries(
        record_store_->server_url(),
        record_id.value()
    );

    if (pending.size() < api::ApiClient::kPendingPageSize) {
        for (const auto& item : pending) {
            held_before.erase(item.delivery_id);
        }
        std::vector<std::string> dropped(held_before.begin(), held_before.end());
        forget_held(dropped);
    }

    for (const auto& item : pending) {
        handle_delivery(item.delivery_id, item.envelope);
    }
}

void DesktopDeliveryService::handle_delivery(const std::string& delivery_id, const nlohmann::json& envelope) {
    auto record_id = record_store_->record_id();
    if (!record_id.has_value() || record_id->empty()) return;

    if (undecryptable_.find(delivery_id) != undecryptable_.end() ||
        holding_.find(delivery_id) != holding_.end()) {
        return;
    }

    if (!in_flight_.insert(delivery_id).second) {
        return;
    }

    prune_finished();
    if (finished_.find(delivery_id) != finished_.end()) {
        ack_async(delivery_id);
        in_flight_.erase(delivery_id);
        return;
    }

    if (!envelope.contains("ciphertext") || !envelope["ciphertext"].is_string()) {
        undecryptable_.insert(delivery_id);
        in_flight_.erase(delivery_id);
        update_status(status_.state);
        return;
    }

    std::string ciphertext = envelope["ciphertext"].get<std::string>();
    auto priv_key = record_store_->private_key();
    auto pub_key = record_store_->public_key();

    if (!priv_key.has_value() || !pub_key.has_value()) {
        in_flight_.erase(delivery_id);
        return;
    }

    notifications::RelayNotification notif;
    try {
        nlohmann::json payload = crypto::decrypt_payload(ciphertext, pub_key.value(), priv_key.value());
        notif = notifications::RelayNotification::from_payload(payload);
    } catch (...) {
        undecryptable_.insert(delivery_id);
        in_flight_.erase(delivery_id);
        update_status(status_.state);
        return;
    }

    holding_[delivery_id] = HeldDelivery{delivery_id, notif,
        std::chrono::steady_clock::now() + timing_.hold, false};
    publish_held();
    in_flight_.erase(delivery_id);
    notify_held(delivery_id);

}

void DesktopDeliveryService::keep_recent_code(
    const std::string& delivery_id,
    const notifications::RelayNotification& notif,
    std::chrono::steady_clock::time_point expires_at
) {
    recent_[delivery_id] = HeldDelivery{
        delivery_id,
        notif,
        expires_at,
        true
    };
    publish_held();
}

void DesktopDeliveryService::forget_held(const std::vector<std::string>& ids) {
    if (ids.empty()) return;
    for (const auto& id : ids) {
        holding_.erase(id);
        finished_[id] = std::chrono::steady_clock::now();
    }
    publish_held();
}

void DesktopDeliveryService::ack_async(const std::string& delivery_id) {
    auto id = record_store_->record_id();
    if (!id || id->empty()) return;
    auto server = record_store_->server_url();
    auto api = api_client_;
    std::thread([api, server, id, delivery_id]() {
        try { api->ack_delivery(server, *id, delivery_id); } catch (...) {}
    }).detach();
}

void DesktopDeliveryService::finish_held(const std::string& delivery_id) {
    forget_held({delivery_id});
    ack_async(delivery_id);
}

void DesktopDeliveryService::notify_held(const std::string& id) {
    auto it = holding_.find(id);
    if (it == holding_.end() || !in_flight_.insert(id).second) return;
    auto alive = alive_;
    auto notification = it->second.notification;
    auto self = shared_from_this();
    notification_service_->show_async(notification, [alive]() { return alive->load(); },
        [self, alive, id](bool notified) {
            if (!alive->load()) return;
            self->in_flight_.erase(id);
            auto current = self->holding_.find(id);
            if (current == self->holding_.end() || !notified) return;
            auto delivery = current->second;
            self->holding_.erase(current);
            self->finished_[id] = std::chrono::steady_clock::now();
            if (delivery.expires_at > std::chrono::steady_clock::now())
                self->keep_recent_code(id, delivery.notification, delivery.expires_at);
            else
                self->publish_held();
            self->ack_async(id);
        });
}

void DesktopDeliveryService::flush_held() {
    std::vector<std::string> ids;
    for (const auto& entry : holding_) ids.push_back(entry.first);
    for (const auto& id : ids) notify_held(id);
}

void DesktopDeliveryService::recheck_held() {
    auto now = std::chrono::steady_clock::now();

    bool recent_changed = false;
    std::vector<std::string> expired_recent;
    for (const auto& [id, del] : recent_) {
        if (del.expires_at <= now) {
            expired_recent.push_back(id);
        }
    }
    for (const auto& id : expired_recent) {
        recent_.erase(id);
        recent_changed = true;
    }

    std::vector<std::string> expired_held;
    for (const auto& [id, del] : holding_) {
        if (del.expires_at <= now) {
            expired_held.push_back(id);
        }
    }
    if (!expired_held.empty()) {
        forget_held(expired_held);
    } else if (recent_changed) {
        publish_held();
    }

    if (holding_.empty()) return;

    flush_held();

    if (holding_.empty()) return;

    try {
        poll_pending_async();
    } catch (const api::RecordNotFoundException&) {
        update_status(DeliveryState::RecordUnknown);
    } catch (...) {}
}

void DesktopDeliveryService::prune_finished() {
    const auto cutoff = std::chrono::steady_clock::now() - std::chrono::hours(24);
    for (auto it = finished_.begin(); it != finished_.end();) {
        if (it->second < cutoff) it = finished_.erase(it);
        else ++it;
    }
}

void DesktopDeliveryService::schedule_reconnect(const std::string& error_msg) {
    if (stopped_) return;

    update_status(DeliveryState::Retrying, error_msg);

    int attempt = reconnect_attempt_++;
    if (error_msg.find("429") != std::string::npos) {
        attempt = std::max(attempt, 4);
    }
    const auto delay = reconnect_backoff_delay(attempt);

    if (reconnect_timer_id_ != 0) {
        g_source_remove(reconnect_timer_id_);
    }

    // Note: Do NOT cancel periodic_poll_timer_id_ or recheck_timer_id_!
    // Periodic polling and held-code expiry checks persist independently across socket drops.
    reconnect_timer_id_ = g_timeout_add(
        static_cast<guint>(delay.count()),
        reconnect_timer_cb,
        this
    );
}

void DesktopDeliveryService::connect_websocket() {
    if (stopped_) return;

    auto record_id = record_store_->record_id();
    if (!record_id.has_value() || record_id->empty()) return;

    std::string ws_url = api_client_->delivery_websocket_url(record_store_->server_url());
    if (socket_alive_) *socket_alive_ = false;
    if (ws_client_) ws_client_->disconnect();
    socket_alive_ = std::make_shared<std::atomic<bool>>(true);
    auto socket_generation = socket_alive_;
    auto generation = alive_;
    auto self = shared_from_this();
    ws_client_ = std::make_unique<WebSocketClient>(
        [self, generation, socket_generation](const std::string& msg) {
            dispatch_to_main(generation, [self, socket_generation, msg]() {
                if (socket_generation->load()) self->on_ws_message(msg);
            });
        },
        [self, generation, socket_generation](bool connected, const std::string& err) {
            dispatch_to_main(generation, [self, socket_generation, connected, err]() {
                if (socket_generation->load()) self->on_ws_status(connected, err);
            });
        });
    ws_client_->connect(ws_url, record_id.value());
}

void DesktopDeliveryService::on_ws_status(bool connected, const std::string& error) {
    if (stopped_) return;

    if (connected) {
        reconnect_attempt_ = 0;
        update_status(DeliveryState::Ready);
        try {
            poll_pending_async();
        } catch (...) {}
    } else {
        schedule_reconnect(error);
    }
}

void DesktopDeliveryService::on_ws_message(const std::string& text) {
    if (stopped_) return;

    try {
        auto j = nlohmann::json::parse(text);
        if (j.contains("type") && j["type"] == "envelope") {
            std::string del_id = j.value("delivery_id", "");
            if (!del_id.empty() && j.contains("envelope")) {
                handle_delivery(del_id, j["envelope"]);
            }
        }
    } catch (...) {}
}

} // namespace delivery
} // namespace pux
