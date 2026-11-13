#pragma once
#include "record_store.hpp"
#include <atomic>
#include <functional>
#include <memory>

namespace pux::storage {
// All backend operations run serially on one owned worker. Callbacks and snapshot
// replacement run on the GLib main context. A generation gates stale results.
class StorageCoordinator {
public:
    using Operation = std::function<void(RecordStore&)>;
    using Completion = std::function<void(const std::string&)>;
    StorageCoordinator(std::shared_ptr<SecretStore> backend, std::shared_ptr<MemorySecretStore> snapshot);
    ~StorageCoordinator();
    void submit(Operation operation, std::shared_ptr<std::atomic<bool>> generation, Completion completion);
    // Durable work must not be cancelled merely because its window was closed.
    void submit_durable(Operation operation, Completion completion) {
        submit(std::move(operation), std::make_shared<std::atomic<bool>>(true), std::move(completion));
    }
    void submit_reset_corrupt_native(Completion completion);
    bool corrupt_native_reset_allowed() const;
private:
    struct State;
    std::shared_ptr<State> state_;
};
}
