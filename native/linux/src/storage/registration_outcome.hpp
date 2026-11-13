#pragma once

#include "record_store.hpp"
#include <optional>
#include <string>

namespace pux::storage {

inline constexpr const char* kUncertainRegistrationKey = "native_linux_uncertain_registration";
inline constexpr const char* kRemovalRegistrationNoticeKey = "native_linux_removal_registration_notice";

inline std::string removal_registration_notice_text() {
    return "This device is removed locally. If a device registration was still in progress, the server "
           "might still hold a stale registration. Delete the relay from another device, or reinstall, "
           "to clean that up.";
}

inline void persist_removal_registration_notice(RecordStore& store) {
    store.secret_store()->write(kRemovalRegistrationNoticeKey, removal_registration_notice_text());
}

inline std::optional<std::string> removal_registration_notice(const RecordStore& store) {
    return store.secret_store()->read(kRemovalRegistrationNoticeKey);
}

inline void clear_removal_registration_notice(RecordStore& store) {
    auto retained = store.secret_store()->read_all();
    retained.erase(kRemovalRegistrationNoticeKey);
    retained.erase(kUncertainRegistrationKey);
    store.secret_store()->replace_all(std::move(retained));
}

inline void mark_registration_outcome_uncertain(RecordStore& store) {
    store.secret_store()->write(kUncertainRegistrationKey, "1");
}

inline void clear_registration_outcome_uncertain(RecordStore& store) {
    store.secret_store()->delete_key(kUncertainRegistrationKey);
}

inline bool registration_outcome_uncertain(const RecordStore& store) {
    return store.secret_store()->contains_key(kUncertainRegistrationKey);
}

} // namespace pux::storage
