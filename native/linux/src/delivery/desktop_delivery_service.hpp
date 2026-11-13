#pragma once

#include <string>
#include <vector>
#include <map>
#include <set>
#include <memory>
#include <chrono>
#include <functional>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include "../vendor/json.hpp"
#include "../api/api_client.hpp"
#include "../storage/record_store.hpp"
#include "../storage/storage_coordinator.hpp"
#include "../notifications/notification_service.hpp"
#include "websocket_client.hpp"

namespace pux {
namespace delivery {

struct HeldDelivery {
    std::string delivery_id;
    notifications::RelayNotification notification;
    std::chrono::steady_clock::time_point expires_at;
    bool notified = false;
};

enum class DeliveryState {
    Idle,
    Connecting,
    Ready,
    Retrying,
    RecordUnknown,
    TooManyDevices
};

struct DeliveryStatus {
    DeliveryState state = DeliveryState::Idle;
    std::string message;
    size_t undecryptable_count = 0;
};

struct DeliveryTiming {
    std::chrono::milliseconds hold{std::chrono::minutes(15)};
    std::chrono::milliseconds recheck{std::chrono::seconds(30)};
    std::chrono::milliseconds poll{std::chrono::seconds(30)};
    std::chrono::milliseconds reconnect{std::chrono::seconds(2)};
    // After the server rejects registration because the relay is at its device
    // limit, registration is retried after `registration_retry`, doubling on each
    // further rejection up to `registration_retry_max`, so a slot freed elsewhere
    // is picked up without a restart.
    std::chrono::milliseconds registration_retry{std::chrono::seconds(30)};
    std::chrono::milliseconds registration_retry_max{std::chrono::minutes(10)};
};

// Matches mobile DeliveryController.backoff (2 s → 5 min with jitter).
std::chrono::milliseconds reconnect_backoff_delay(int attempt, uint32_t jitter_ms = 0);

// Delay before retry number `attempt` (0-based) of a registration the server
// rejected for the device limit: base * 2^attempt, never above `max`.
std::chrono::milliseconds registration_retry_delay(
    int attempt, std::chrono::milliseconds base, std::chrono::milliseconds max);

struct RegistrationActivity {
    mutable std::mutex mutex;
    std::condition_variable changed;
    unsigned active = 0;
    std::map<std::string, std::string> devices;
    void begin() { std::lock_guard<std::mutex> lock(mutex); ++active; }
    void end() { std::lock_guard<std::mutex> lock(mutex); if (active > 0) --active; changed.notify_all(); }
    bool has_active() const {
        std::lock_guard<std::mutex> lock(mutex);
        return active > 0;
    }
    void wait() { std::unique_lock<std::mutex> lock(mutex); changed.wait(lock, [this] { return active == 0; }); }
    void remember(const std::string& record, const std::string& device) {
        if (!device.empty()) { std::lock_guard<std::mutex> lock(mutex); devices[record] = device; }
    }
    std::string device_for(const std::string& record) {
        std::lock_guard<std::mutex> lock(mutex);
        auto it = devices.find(record); return it == devices.end() ? std::string{} : it->second;
    }
};

class DesktopDeliveryService : public std::enable_shared_from_this<DesktopDeliveryService> {
public:
    static constexpr std::chrono::minutes kHoldFor{15};
    static constexpr std::chrono::seconds kHoldRecheckInterval{30};
    // Fallback poll while connected (aligned with kHoldRecheckInterval); primary delivery is WebSocket.
    static constexpr std::chrono::seconds kPeriodicPollInterval{30};
    static constexpr std::chrono::hours kRegistrationInterval{12};

    using StatusCallback = std::function<void(const DeliveryStatus& status)>;
    using HeldChangedCallback = std::function<void(const std::vector<HeldDelivery>& held, const std::vector<HeldDelivery>& recent)>;

    DesktopDeliveryService(
        std::shared_ptr<storage::RecordStore> record_store,
        std::shared_ptr<api::ApiClient> api_client,
        std::shared_ptr<notifications::NotificationService> notification_service,
        DeliveryTiming timing = {},
        std::shared_ptr<storage::StorageCoordinator> storage = nullptr
    );
    virtual ~DesktopDeliveryService();

    void set_status_callback(StatusCallback cb) { status_cb_ = std::move(cb); }
    void set_held_callback(HeldChangedCallback cb) { held_cb_ = std::move(cb); }

    const DeliveryStatus& status() const { return status_; }
    std::vector<HeldDelivery> held_deliveries() const;
    std::vector<HeldDelivery> recent_deliveries() const;

    // Start delivery service (register device, poll pending, connect websocket, start periodic polling)
    virtual void start();

    // Stop delivery service and clean up in-memory held/recent codes (used on user logout/removal)
    virtual void stop();
    void suspend();
    // Called on a worker before destructive server requests after suspend().
    void wait_for_registration() { registration_activity_->wait(); }
    std::string registered_device_id(const std::string& record) { return registration_activity_->device_for(record); }

    // Trigger manual poll (synchronous, for tests or explicit triggers)
    void poll_pending();

    // Non-blocking poll run from timers
    void poll_pending_async();

    // Process a single delivery envelope
    void handle_delivery(const std::string& delivery_id, const nlohmann::json& envelope);

    // Periodic check of held and recent codes
    void recheck_held();

    // Periodic re-registration of device token
    void register_device();
    void register_device_async();

    // Reconnection handling without wiping held or recent codes
    void schedule_reconnect(const std::string& error_msg = "");

    // Socket-only reconnect invoked by reconnect timer
    void reconnect_socket();

    // User-initiated retry after the server rejected registration for the device
    // limit (the Retry action). Restarts the backoff and registers immediately.
    // Returns false, doing nothing, unless the service is running, no
    // registration is already in flight and the last attempt hit the limit.
    bool retry_registration();

    void clear_reconnect_timer_id() { reconnect_timer_id_ = 0; }
    uint32_t reconnect_timer_id() const { return reconnect_timer_id_; }
    void clear_registration_retry_timer_id() { registration_retry_timer_id_ = 0; }
    uint32_t registration_retry_timer_id() const { return registration_retry_timer_id_; }
    uint32_t periodic_poll_timer_id() const { return periodic_poll_timer_id_; }
    uint32_t recheck_timer_id() const { return recheck_timer_id_; }

    void ensure_periodic_poll_timer();
    void ensure_recheck_timer();

    bool is_stopped() const { return stopped_; }
    bool registration_in_flight() const { return registration_in_flight_; }
    bool registration_activity_active() const { return registration_activity_->has_active(); }
    bool registration_outcome_uncertain() const;
    using RegistrationFenceCallback = std::function<void(const std::string& error)>;
    // Runs continuation on the GLib main thread after any async registration fence.
    void prepare_for_device_removal(RegistrationFenceCallback continuation);
    void mark_registration_outcome_uncertain_async(storage::StorageCoordinator::Completion completion = nullptr);
    void clear_registration_outcome_uncertain_async(storage::StorageCoordinator::Completion completion = nullptr);

    void update_status(DeliveryState state, const std::string& message = "");

private:
    std::shared_ptr<storage::RecordStore> record_store_;
    std::shared_ptr<api::ApiClient> api_client_;
    std::shared_ptr<notifications::NotificationService> notification_service_;
    DeliveryTiming timing_;
    std::shared_ptr<storage::StorageCoordinator> storage_;
    void persist_registration(const std::string& id, bool connect_after);
    std::shared_ptr<RegistrationActivity> registration_activity_ = std::make_shared<RegistrationActivity>();

    StatusCallback status_cb_;
    HeldChangedCallback held_cb_;

    DeliveryStatus status_;
    bool stopped_ = true;
    bool poll_in_flight_ = false;
    bool registration_in_flight_ = false;
    bool registered_ = false;
    int reconnect_attempt_ = 0;
    int registration_retry_attempt_ = 0;

    std::shared_ptr<std::atomic<bool>> alive_;
    std::shared_ptr<std::atomic<bool>> socket_alive_;

    // All delivery state is confined to the main GLib thread
    std::set<std::string> undecryptable_;
    std::set<std::string> in_flight_;
    std::map<std::string, std::chrono::steady_clock::time_point> finished_;
    void prune_finished();

    std::map<std::string, HeldDelivery> holding_;
    std::map<std::string, HeldDelivery> recent_;

    uint32_t recheck_timer_id_ = 0;
    uint32_t registration_timer_id_ = 0;
    uint32_t reconnect_timer_id_ = 0;
    uint32_t periodic_poll_timer_id_ = 0;
    uint32_t registration_retry_timer_id_ = 0;

    std::unique_ptr<WebSocketClient> ws_client_;

    // Main thread: the server refused registration because the relay is at its
    // device limit. Shows the state and schedules a bounded background retry.
    void handle_device_limit_rejection();
    void schedule_registration_retry();
    void cancel_registration_retry();

    void publish_held();
    void forget_held(const std::vector<std::string>& ids);
    void keep_recent_code(const std::string& delivery_id, const notifications::RelayNotification& notif, std::chrono::steady_clock::time_point expires_at);
    void finish_held(const std::string& delivery_id);
    void flush_held();
    void notify_held(const std::string& delivery_id);
    void ack_async(const std::string& delivery_id);

    void connect_websocket();
    void on_ws_message(const std::string& text);
    void on_ws_status(bool connected, const std::string& error);

    void cancel_timers();
};

} // namespace delivery
} // namespace pux
