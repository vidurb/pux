#include "storage_coordinator.hpp"
#include "secret_store.hpp"
#include <glib.h>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <iostream>

namespace pux::storage {

namespace {

void refresh_corrupt_reset_allowed(
    const std::shared_ptr<SecretStore>& backend,
    std::atomic<bool>& corrupt_native_reset_allowed
) {
    corrupt_native_reset_allowed = false;
    auto* secret_service = dynamic_cast<SecretServiceStore*>(backend.get());
    if (!secret_service) {
        return;
    }
    if (secret_service->last_read_state() == SecretServiceStore::ReadState::Corrupt &&
        !secret_service->legacy_enrollment_pending()) {
        corrupt_native_reset_allowed = true;
    }
}

} // namespace

struct StorageCoordinator::State {
    enum class TaskKind {
        Normal,
        ResetCorruptNative,
    };

    struct Task {
        TaskKind kind = TaskKind::Normal;
        Operation operation;
        std::shared_ptr<std::atomic<bool>> generation;
        Completion completion;
    };
    std::mutex mutex;
    std::condition_variable ready;
    std::deque<Task> tasks;
    bool shutdown = false;
    std::shared_ptr<SecretStore> backend;
    std::shared_ptr<MemorySecretStore> snapshot;
    std::atomic<bool> corrupt_native_reset_allowed{false};
};

StorageCoordinator::StorageCoordinator(std::shared_ptr<SecretStore> backend, std::shared_ptr<MemorySecretStore> snapshot)
    : state_(std::make_shared<State>()) {
    auto state = state_;
    state->backend = std::move(backend);
    state->snapshot = std::move(snapshot);
    std::thread([state] {
        RecordStore real(state->backend);
        for (;;) {
            State::Task task;
            {
                std::unique_lock<std::mutex> lock(state->mutex);
                state->ready.wait(lock, [&] { return state->shutdown || !state->tasks.empty(); });
                if (state->shutdown) break;
                task = std::move(state->tasks.front());
                state->tasks.pop_front();
            }
            if (!task.generation->load()) {
                continue;
            }
            std::string error;
            std::map<std::string, std::string> data;
            try {
                if (task.kind == State::TaskKind::ResetCorruptNative) {
                    auto* secret_service = dynamic_cast<SecretServiceStore*>(state->backend.get());
                    if (!secret_service) {
                        throw StorageException("Keyring reset is only available with Secret Service storage");
                    }
                    if (secret_service->legacy_enrollment_pending()) {
                        throw LegacyEnrollmentPendingException();
                    }
                    if (secret_service->last_read_state() != SecretServiceStore::ReadState::Corrupt) {
                        throw KeyringCorruptException();
                    }
                    secret_service->clear();
                    data = state->backend->read_all();
                    state->corrupt_native_reset_allowed = false;
                } else {
                    real.init();
                    if (!task.generation->load()) {
                        continue;
                    }
                    task.operation(real);
                    if (real.is_enrolled()) {
                        (void)real.desktop_device_id();
                    }
                    data = state->backend->read_all();
                    state->corrupt_native_reset_allowed = false;
                }
            } catch (const KeyringCorruptException& e) {
                error = e.what();
                refresh_corrupt_reset_allowed(state->backend, state->corrupt_native_reset_allowed);
            } catch (const std::exception& e) {
                error = e.what();
                state->corrupt_native_reset_allowed = false;
            } catch (...) {
                error = "Unknown keyring error";
                state->corrupt_native_reset_allowed = false;
            }

            struct Result {
                State::Task task;
                std::shared_ptr<MemorySecretStore> snapshot;
                std::map<std::string, std::string> data;
                std::string error;
            };
            auto* result = new Result{std::move(task), state->snapshot, std::move(data), std::move(error)};
            g_idle_add_full(
                G_PRIORITY_DEFAULT,
                +[](gpointer ptr) -> gboolean {
                    auto* result = static_cast<Result*>(ptr);
                    if (result->task.generation->load()) {
                        try {
                            if (result->error.empty()) {
                                result->snapshot->replace(std::move(result->data));
                            }
                            if (result->task.completion) {
                                result->task.completion(result->error);
                            }
                        } catch (const std::exception& e) {
                            std::cerr << "Storage callback failed: " << e.what() << "\n";
                        } catch (...) {
                            std::cerr << "Storage callback failed\n";
                        }
                    }
                    return G_SOURCE_REMOVE;
                },
                result,
                +[](gpointer ptr) { delete static_cast<Result*>(ptr); }
            );
        }
    }).detach();
}

StorageCoordinator::~StorageCoordinator() {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->shutdown = true;
    state_->tasks.clear();
    state_->ready.notify_one();
}

bool StorageCoordinator::corrupt_native_reset_allowed() const {
    return state_->corrupt_native_reset_allowed.load();
}

void StorageCoordinator::submit(
    Operation operation,
    std::shared_ptr<std::atomic<bool>> generation,
    Completion completion
) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->tasks.push_back({
        State::TaskKind::Normal,
        std::move(operation),
        std::move(generation),
        std::move(completion)
    });
    state_->ready.notify_one();
}

void StorageCoordinator::submit_reset_corrupt_native(Completion completion) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->tasks.push_back({
        State::TaskKind::ResetCorruptNative,
        {},
        std::make_shared<std::atomic<bool>>(true),
        std::move(completion)
    });
    state_->ready.notify_one();
}

} // namespace pux::storage
