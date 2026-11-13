#include "removal_controller.hpp"
#include "../storage/registration_outcome.hpp"

namespace pux::ui {
RemovalController::RemovalController(std::shared_ptr<storage::StorageCoordinator> storage,
    std::shared_ptr<api::ApiClient> api, std::shared_ptr<delivery::DesktopDeliveryService> service,
    std::function<void(bool)> application_hold)
    : storage_(std::move(storage)), api_(std::move(api)), service_(std::move(service)), hold_(std::move(application_hold)) {}
RemovalController::~RemovalController() { set_hold(false); }
void RemovalController::set_hold(bool value) { if (held_ != value) { held_ = value; hold_(value); } }
void RemovalController::notify() { if (observer_) observer_(); }
void RemovalController::begin(std::string action, std::string record_id, std::string device_id) {
    if (state_.phase != Phase::Idle) return;
    auto self = shared_from_this();
    set_hold(true);
    if (action == "device") {
        state_ = {Phase::Running, action, record_id, device_id, "", false, ""};
        remote_possible_ = false;
        cleanup_complete_ = false;
        notify();
        service_->prepare_for_device_removal([self, action = std::move(action), record_id = std::move(record_id),
                                                 device_id = std::move(device_id)](const std::string& fence_error) mutable {
            if (self->state_.phase == Phase::Idle) {
                self->set_hold(false);
                return;
            }
            if (!fence_error.empty()) {
                self->pending_device_fence_ = true;
                self->state_ = {Phase::Unconfirmed, action, record_id, device_id,
                    "Could not record registration uncertainty before removal: " + fence_error, true, ""};
                self->remote_possible_ = false;
                self->cleanup_complete_ = false;
                self->notify();
                return;
            }
            self->pending_device_fence_ = false;
            self->start_removal_after_registration_fence(std::move(action), std::move(record_id), std::move(device_id));
        });
        return;
    }
    start_removal_after_registration_fence(std::move(action), std::move(record_id), std::move(device_id));
}

void RemovalController::restore_post_removal_notice_from_store(const storage::RecordStore& store) {
    if (state_.phase != Phase::Idle) return;
    auto notice = storage::removal_registration_notice(store);
    if (!notice || notice->empty()) return;
    state_.post_success_notice = *notice;
    notify();
}

void RemovalController::start_removal_after_registration_fence(
    std::string action, std::string record_id, std::string device_id) {
    if (state_.phase != Phase::Idle && state_.phase != Phase::Running) return;

    warn_uncertain_registration_ = false;
    if (action == "device") {
        warn_uncertain_registration_ =
            service_->registration_in_flight() || service_->registration_activity_active() ||
            service_->registration_outcome_uncertain();
        const std::string registered = service_->registered_device_id(record_id);
        if (!registered.empty() && !device_id.empty() && registered != device_id) {
            warn_uncertain_registration_ = true;
        }
    }

    state_ = {Phase::Running, std::move(action), std::move(record_id), std::move(device_id), "", false, ""};
    remote_possible_ = false;
    cleanup_complete_ = false;
    service_->suspend();
    set_hold(true);
    run();
}
void RemovalController::run() {
    auto self = shared_from_this();
    auto request = state_;
    auto confirmed = std::make_shared<std::atomic<bool>>(false);
    auto completed = std::make_shared<std::atomic<bool>>(false);
    bool refresh_only = cleanup_complete_;
    const bool warn_registration = warn_uncertain_registration_;
    state_.phase = Phase::Running; state_.error.clear(); state_.can_cancel = false;
    set_hold(true); notify();
    storage_->submit_durable([self, request, confirmed, completed, refresh_only, warn_registration](storage::RecordStore& store) {
        if (refresh_only) { *completed = true; return; }
        auto record = store.record_id();
        if (!record || *record != request.record_id) throw storage::StorageException("Pending removal does not match the stored relay");
        storage::RemovalIntent intent{
            request.action,
            request.record_id,
            request.device_id,
            warn_registration && request.action == "device",
        };
        storage::persist_removal_intent(store, intent);
        *confirmed = true;
        self->service_->wait_for_registration();
        storage::complete_removal(store, *self->api_, intent, false);
        *completed = true;
    }, [self, confirmed, completed, request, warn_registration](const std::string& error) {
        if (error.empty()) {
            std::string notice;
            if (warn_registration && request.action == "device") {
                notice = storage::removal_registration_notice_text();
            }
            self->service_->stop();
            State done;
            done.post_success_notice = std::move(notice);
            self->state_ = std::move(done);
            self->remote_possible_ = false;
            self->cleanup_complete_ = false;
            self->warn_uncertain_registration_ = false;
            self->set_hold(false);
        } else {
            if (completed->load()) self->cleanup_complete_ = true;
            if (confirmed->load() && request.action != "local") self->remote_possible_ = true;
            self->state_.phase = confirmed->load() && !self->cleanup_complete_ ? Phase::Durable : Phase::Unconfirmed;
            self->state_.error = error;
            self->state_.can_cancel = !self->cleanup_complete_ && !self->remote_possible_ && request.action != "local" && !confirmed->load();
            // A failed/ambiguous marker write cannot survive process exit reliably.
            self->set_hold(!confirmed->load() || self->cleanup_complete_);
        }
        self->notify();
    });
}
void RemovalController::retry_device_registration_fence() {
    auto self = shared_from_this();
    auto action = state_.action;
    auto record_id = state_.record_id;
    auto device_id = state_.device_id;
    state_ = {Phase::Running, action, record_id, device_id, "", false, ""};
    set_hold(true);
    notify();
    service_->prepare_for_device_removal([self, action = std::move(action), record_id = std::move(record_id),
                                             device_id = std::move(device_id)](const std::string& fence_error) mutable {
        if (self->state_.phase == Phase::Idle) {
            self->set_hold(false);
            return;
        }
        if (!fence_error.empty()) {
            self->pending_device_fence_ = true;
            self->state_ = {Phase::Unconfirmed, action, record_id, device_id,
                "Could not record registration uncertainty before removal: " + fence_error, true, ""};
            self->notify();
            return;
        }
        self->pending_device_fence_ = false;
        self->start_removal_after_registration_fence(std::move(action), std::move(record_id), std::move(device_id));
    });
}

void RemovalController::retry() {
    if (state_.phase != Phase::Unconfirmed && state_.phase != Phase::Durable) return;
    if (pending_device_fence_ && state_.action == "device") {
        retry_device_registration_fence();
        return;
    }
    run();
}
void RemovalController::forget_locally() {
    if (state_.phase != Phase::Unconfirmed && state_.phase != Phase::Durable) return;
    state_.action = "local"; run();
}
void RemovalController::clear_post_success_notice(NoticeClearCallback done) {
    if (state_.post_success_notice.empty()) {
        if (done) done("");
        return;
    }
    auto self = shared_from_this();
    storage_->submit_durable([](storage::RecordStore& store) {
        storage::clear_removal_registration_notice(store);
    }, [self, done](const std::string& error) {
        if (error.empty()) {
            self->state_.post_success_notice.clear();
        }
        if (done) done(error);
        self->notify();
    });
}

void RemovalController::cancel() {
    if (state_.phase != Phase::Unconfirmed || !state_.can_cancel) return;
    auto self = shared_from_this(); auto request = state_;
    state_.phase = Phase::Running; state_.error.clear(); set_hold(true); notify();
    storage_->submit_durable([request](storage::RecordStore& store) {
        if (store.record_id() != std::optional<std::string>(request.record_id))
            throw storage::StorageException("Enrollment changed; removal cannot be cancelled safely");
        auto marker = store.secret_store()->read(storage::kRemovalIntentKey);
        if (!marker) return;
        try {
            auto value = nlohmann::json::parse(*marker);
            if (value.at("record_id").get<std::string>() != request.record_id ||
                value.at("action").get<std::string>() != request.action ||
                value.at("device_id").get<std::string>() != request.device_id ||
                value.at("server").get<std::string>() != store.server_url())
                throw storage::StorageException("A different pending removal exists");
        } catch (const storage::StorageException&) { throw; }
          catch (...) { throw storage::StorageException("Cannot verify the pending removal"); }
        store.secret_store()->delete_key(storage::kRemovalIntentKey);
        if (store.secret_store()->read(storage::kRemovalIntentKey))
            throw storage::StorageException("The pending removal could not be cleared");
    }, [self](const std::string& error) {
        if (error.empty()) { self->state_ = {}; self->remote_possible_ = false; self->set_hold(false); }
        else { self->state_.phase = Phase::Unconfirmed; self->state_.error = error; self->state_.can_cancel = true; }
        self->notify();
    });
}
}
