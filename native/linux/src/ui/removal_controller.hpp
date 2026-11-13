#pragma once
#include "../storage/storage_coordinator.hpp"
#include "../storage/removal_intent.hpp"
#include "../delivery/desktop_delivery_service.hpp"
#include <functional>
#include <memory>

namespace pux::ui {
class RemovalController : public std::enable_shared_from_this<RemovalController> {
public:
    enum class Phase { Idle, Running, Unconfirmed, Durable };
    struct State {
        Phase phase = Phase::Idle;
        std::string action, record_id, device_id, error;
        bool can_cancel = false;
        std::string post_success_notice;
    };
    using Observer = std::function<void()>;
    RemovalController(std::shared_ptr<storage::StorageCoordinator> storage,
        std::shared_ptr<api::ApiClient> api, std::shared_ptr<delivery::DesktopDeliveryService> service,
        std::function<void(bool)> application_hold);
    ~RemovalController();
    const State& state() const { return state_; }
    void set_observer(Observer observer) { observer_ = std::move(observer); }
    void begin(std::string action, std::string record_id, std::string device_id);
    void retry();
    void forget_locally();
    void cancel();
    using NoticeClearCallback = std::function<void(const std::string& error)>;
    void clear_post_success_notice(NoticeClearCallback done = nullptr);
    void restore_post_removal_notice_from_store(const storage::RecordStore& store);
private:
    std::shared_ptr<storage::StorageCoordinator> storage_;
    std::shared_ptr<api::ApiClient> api_;
    std::shared_ptr<delivery::DesktopDeliveryService> service_;
    std::function<void(bool)> hold_;
    Observer observer_;
    State state_;
    bool held_ = false;
    bool remote_possible_ = false;
    bool cleanup_complete_ = false;
    bool warn_uncertain_registration_ = false;
    bool pending_device_fence_ = false;
    void run();
    void retry_device_registration_fence();
    void start_removal_after_registration_fence(std::string action, std::string record_id, std::string device_id);
    void set_hold(bool value);
    void notify();
};
}
