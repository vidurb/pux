#pragma once

#include <string>

namespace pux::storage {

// Counts Secret Service items for one account label (native schema name "default" vs legacy).
struct KeyringEnrollmentItemCounts {
    int native_items = 0;
    int legacy_items = 0;
};

#if defined(__linux__) && defined(HAVE_LIBSECRET)
KeyringEnrollmentItemCounts probe_keyring_enrollment_items(
    const std::string& account_attribute,
    const std::string& item_label
);
bool clear_keyring_account_items(
    const std::string& account_attribute,
    const std::string& item_label
);
#endif

} // namespace pux::storage
