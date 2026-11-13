#pragma once

#include <curl/curl.h>
#include <string>
#include <vector>
#include <functional>
#include <atomic>
#include <thread>
#include <memory>
#include <cstdint>
#include <mutex>

namespace pux {
namespace delivery {

// RFC 6455 Handshake Helpers
std::string compute_sec_ws_accept(const std::string& sec_ws_key);

std::string build_ws_handshake_request(
    const std::string& host_with_port,
    const std::string& path,
    const std::string& record_id,
    const std::string& sec_ws_key
);

bool parse_ws_handshake_response(
    const std::string& headers,
    const std::string& expected_accept,
    std::string& error_reason
);

// Force HTTP/1.1 for the TLS connect used before the WebSocket upgrade (avoids ALPN h2).
void apply_ws_connect_curl_options(CURL* curl);

class WebSocketClient {
public:
    using MessageCallback = std::function<void(const std::string& message)>;
    using StatusCallback = std::function<void(bool connected, const std::string& error)>;

    WebSocketClient(
        MessageCallback on_message,
        StatusCallback on_status
    );
    ~WebSocketClient();

    void connect(const std::string& ws_url, const std::string& record_id);
    void disconnect();
    bool is_connected() const;

private:
    MessageCallback on_message_;
    StatusCallback on_status_;

    struct State {
        std::atomic<bool> connected{false};
        std::atomic<bool> stop{false};
        std::shared_ptr<std::atomic<bool>> alive = std::make_shared<std::atomic<bool>>(true);
        std::mutex callback_mutex;
        MessageCallback message;
        StatusCallback status;
    };
    std::shared_ptr<State> state_;
    static void run_worker(const std::string& ws_url, const std::string& record_id, std::shared_ptr<State> state);

};

} // namespace delivery
} // namespace pux
