#pragma once
#include <curl/curl.h>
#include <mutex>
#include <stdexcept>

namespace pux::api {
inline void ensure_curl_initialized() {
    static std::once_flag once;
    std::call_once(once, [] {
        if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK)
            throw std::runtime_error("Failed to initialize libcurl");
    });
}
}
