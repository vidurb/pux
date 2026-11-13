#include "websocket_client.hpp"
#include "ws_keepalive.hpp"
#include "../api/curl_init.hpp"
#include <wslay/wslay.h>
#include <curl/curl.h>
#include <glib.h>
#include <sodium.h>
#include <poll.h>
#include <cstring>
#include <iostream>
#include <chrono>
#include <sstream>
#include <algorithm>

namespace pux {
namespace delivery {

std::string compute_sec_ws_accept(const std::string& sec_ws_key) {
    std::string magic = sec_ws_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    GChecksum* checksum = g_checksum_new(G_CHECKSUM_SHA1);
    g_checksum_update(checksum, reinterpret_cast<const guchar*>(magic.data()), magic.size());
    uint8_t digest[20];
    gsize digest_len = sizeof(digest);
    g_checksum_get_digest(checksum, digest, &digest_len);
    g_checksum_free(checksum);

    char b64[64];
    sodium_bin2base64(b64, sizeof(b64), digest, digest_len, sodium_base64_VARIANT_ORIGINAL);
    return std::string(b64);
}

std::string build_ws_handshake_request(
    const std::string& host_with_port,
    const std::string& path,
    const std::string& record_id,
    const std::string& sec_ws_key
) {
    std::string req;
    req += "GET " + path + " HTTP/1.1\r\n";
    req += "Host: " + host_with_port + "\r\n";
    req += "Upgrade: websocket\r\n";
    req += "Connection: Upgrade\r\n";
    req += "Sec-WebSocket-Key: " + sec_ws_key + "\r\n";
    req += "Sec-WebSocket-Version: 13\r\n";
    req += "x-pux-token: " + record_id + "\r\n";
    req += "\r\n";
    return req;
}

namespace {

std::string to_lower(const std::string& str) {
    std::string lower = str;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return lower;
}

std::string trim(const std::string& s) {
    size_t start = s.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) return "";
    size_t end = s.find_last_not_of(" \t\r\n");
    return s.substr(start, end - start + 1);
}

// Parses url into http(s) URL and host_with_port / path
struct ParsedWsUrl {
    std::string http_url;
    std::string host_with_port;
    std::string path;
};

ParsedWsUrl parse_url_for_connect(const std::string& raw) {
    ParsedWsUrl res;
    std::string s = raw;
    std::string scheme = "http";
    if (s.rfind("wss://", 0) == 0) {
        scheme = "https";
        s = s.substr(6);
    } else if (s.rfind("ws://", 0) == 0) {
        scheme = "http";
        s = s.substr(5);
    } else if (s.rfind("https://", 0) == 0) {
        scheme = "https";
        s = s.substr(8);
    } else if (s.rfind("http://", 0) == 0) {
        scheme = "http";
        s = s.substr(7);
    }

    size_t slash = s.find('/');
    if (slash != std::string::npos) {
        res.host_with_port = s.substr(0, slash);
        res.path = s.substr(slash);
    } else {
        res.host_with_port = s;
        res.path = "/";
    }

    res.http_url = scheme + "://" + res.host_with_port + res.path;
    return res;
}

bool send_all(
    CURL* curl,
    const void* data,
    size_t total_len,
    const std::atomic<bool>& stop_requested,
    std::chrono::milliseconds timeout = std::chrono::milliseconds(5000)
) {
    const uint8_t* ptr = static_cast<const uint8_t*>(data);
    size_t remaining = total_len;
    auto start = std::chrono::steady_clock::now();

    while (remaining > 0 && !stop_requested) {
        size_t sent = 0;
        CURLcode res = curl_easy_send(curl, ptr, remaining, &sent);
        if (res == CURLE_OK && sent > 0) {
            ptr += sent;
            remaining -= sent;
        } else if (res == CURLE_AGAIN) {
            if (std::chrono::steady_clock::now() - start > timeout) {
                return false;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        } else {
            return false;
        }
    }
    return remaining == 0;
}

struct WslayUserData {
    CURL* curl = nullptr;
    std::vector<uint8_t> rx_buffer;
    std::function<void(const std::string&)> on_message;
    bool peer_closed = false;
    std::shared_ptr<std::atomic<bool>> alive;
    WsKeepaliveState keepalive{};
};

ssize_t ws_recv_callback(
    wslay_event_context_ptr ctx,
    uint8_t *buf, size_t len,
    int /*flags*/,
    void *user_data
) {
    auto* ud = static_cast<WslayUserData*>(user_data);

    if (!ud->rx_buffer.empty()) {
        size_t to_copy = std::min(len, ud->rx_buffer.size());
        std::memcpy(buf, ud->rx_buffer.data(), to_copy);
        ud->rx_buffer.erase(ud->rx_buffer.begin(), ud->rx_buffer.begin() + to_copy);
        return static_cast<ssize_t>(to_copy);
    }

    size_t nread = 0;
    CURLcode res = curl_easy_recv(ud->curl, buf, len, &nread);
    if (res == CURLE_OK && nread > 0) {
        return static_cast<ssize_t>(nread);
    }
    if (res == CURLE_AGAIN) {
        wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
        return -1;
    }
    if (res == CURLE_OK && nread == 0) {
        return 0; // EOF
    }
    wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
    return -1;
}

ssize_t ws_send_callback(
    wslay_event_context_ptr ctx,
    const uint8_t *data, size_t len,
    int /*flags*/,
    void *user_data
) {
    auto* ud = static_cast<WslayUserData*>(user_data);
    size_t sent = 0;
    CURLcode res = curl_easy_send(ud->curl, data, len, &sent);
    if (res == CURLE_OK && sent > 0) {
        return static_cast<ssize_t>(sent);
    }
    if (res == CURLE_AGAIN) {
        wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
        return -1;
    }
    wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
    return -1;
}

int ws_genmask_callback(
    wslay_event_context_ptr /*ctx*/,
    uint8_t *buf, size_t len,
    void * /*user_data*/
) {
    randombytes_buf(buf, len);
    return 0;
}

void ws_on_msg_recv_callback(
    wslay_event_context_ptr /*ctx*/,
    const struct wslay_event_on_msg_recv_arg *arg,
    void *user_data
) {
    auto* ud = static_cast<WslayUserData*>(user_data);
    if (arg->opcode == WSLAY_TEXT_FRAME) {
        if (ud->alive->load()) {
            std::string msg(reinterpret_cast<const char*>(arg->msg), arg->msg_length);
            ud->on_message(msg);
        }
    } else if (arg->opcode == WSLAY_PONG) {
        ws_keepalive_on_pong(ud->keepalive, std::chrono::steady_clock::now());
    } else if (arg->opcode == WSLAY_CONNECTION_CLOSE) {
        ud->peer_closed = true;
    }
}

} // namespace

void apply_ws_connect_curl_options(CURL* curl) {
    if (!curl) return;
    curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, static_cast<long>(CURL_HTTP_VERSION_1_1));
    // CURLOPT_SSL_ENABLE_ALPN is a long option, not a preprocessor macro (Terra).
    curl_easy_setopt(curl, CURLOPT_SSL_ENABLE_ALPN, 0L);
}

bool parse_ws_handshake_response(
    const std::string& headers,
    const std::string& expected_accept,
    std::string& error_reason
) {
    std::istringstream stream(headers);
    std::string status_line;
    if (!std::getline(stream, status_line)) {
        error_reason = "Empty response";
        return false;
    }
    status_line = trim(status_line);

    if ((status_line.rfind("HTTP/1.1 101", 0) != 0 && status_line.rfind("HTTP/1.0 101", 0) != 0) ||
        (status_line.size() > 12 && status_line[12] != ' ')) {
        error_reason = "Expected HTTP 101 Switching Protocols, got: " + status_line;
        return false;
    }

    bool has_upgrade_websocket = false;
    bool has_connection_upgrade = false;
    bool has_valid_accept = false;
    std::string actual_accept;

    std::string line;
    while (std::getline(stream, line)) {
        line = trim(line);
        if (line.empty()) break;

        size_t colon = line.find(':');
        if (colon == std::string::npos) continue;

        std::string name = to_lower(trim(line.substr(0, colon)));
        std::string value = trim(line.substr(colon + 1));
        std::string val_lower = to_lower(value);

        if (name == "upgrade") {
            if (val_lower == "websocket") {
                has_upgrade_websocket = true;
            }
        } else if (name == "connection") {
            std::istringstream tokens(val_lower);
            std::string token;
            while (std::getline(tokens, token, ',')) {
                if (trim(token) == "upgrade") has_connection_upgrade = true;
            }
        } else if (name == "sec-websocket-accept") {
            actual_accept = value;
            if (!expected_accept.empty() && value == expected_accept) {
                has_valid_accept = true;
            }
        }
    }

    if (!has_upgrade_websocket) {
        error_reason = "Missing or invalid Upgrade header";
        return false;
    }
    if (!has_connection_upgrade) {
        error_reason = "Missing or invalid Connection header";
        return false;
    }
    if (!expected_accept.empty() && !has_valid_accept) {
        error_reason = "Sec-WebSocket-Accept mismatch: expected " + expected_accept + ", got " + actual_accept;
        return false;
    }

    return true;
}

WebSocketClient::WebSocketClient(MessageCallback on_message, StatusCallback on_status)
    : on_message_(std::move(on_message)), on_status_(std::move(on_status)) {}
WebSocketClient::~WebSocketClient() { disconnect(); }

bool WebSocketClient::is_connected() const { return state_ && state_->connected.load(); }

void WebSocketClient::disconnect() {
    auto state = std::move(state_);
    if (!state) return;
    state->stop = true;
    std::lock_guard<std::mutex> lock(state->callback_mutex);
    *state->alive = false;
}

void WebSocketClient::connect(const std::string& ws_url, const std::string& record_id) {
    disconnect();
    api::ensure_curl_initialized();
    auto state = std::make_shared<State>();
    state->message = on_message_;
    state->status = on_status_;
    state_ = state;
    std::thread([ws_url, record_id, state]() { run_worker(ws_url, record_id, state); }).detach();
}

void WebSocketClient::run_worker(const std::string& ws_url, const std::string& record_id,
                                  std::shared_ptr<State> state) {
    auto alive = state->alive;
    auto status = [state](bool connected, const std::string& error) {
        std::lock_guard<std::mutex> lock(state->callback_mutex);
        if (state->alive->load()) state->status(connected, error);
    };
    auto parsed = parse_url_for_connect(ws_url);

    CURL* curl = curl_easy_init();
    if (!curl) {
        if (!state->stop && alive->load()) {
            status(false, "Failed to initialize curl handle");
        }
        return;
    }

    // CURLOPT_CONNECT_ONLY = 1L establishes raw TCP/TLS connection
    // Baseline supported in libcurl 7.18.2+ across all Linux distributions (including Ubuntu 22.04)
    curl_easy_setopt(curl, CURLOPT_URL, parsed.http_url.c_str());
    apply_ws_connect_curl_options(curl);
    curl_easy_setopt(curl, CURLOPT_CONNECT_ONLY, 1L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION,
        +[](void* data, curl_off_t, curl_off_t, curl_off_t, curl_off_t) -> int {
            return static_cast<std::atomic<bool>*>(data)->load() ? 1 : 0;
        });
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &state->stop);

    CURLcode res = curl_easy_perform(curl);
    if (res != CURLE_OK) {
        std::string err = curl_easy_strerror(res);
        curl_easy_cleanup(curl);
        if (!state->stop && alive->load()) {
            status(false, "Connection failed: " + err);
        }
        return;
    }

    // Build and send RFC 6455 HTTP Upgrade handshake
    uint8_t nonce[16];
    randombytes_buf(nonce, 16);
    char b64_key[64];
    sodium_bin2base64(b64_key, sizeof(b64_key), nonce, sizeof(nonce), sodium_base64_VARIANT_ORIGINAL);
    std::string client_key(b64_key);
    std::string expected_accept = compute_sec_ws_accept(client_key);

    std::string req = build_ws_handshake_request(
        parsed.host_with_port,
        parsed.path,
        record_id,
        client_key
    );

    if (!send_all(curl, req.data(), req.size(), state->stop)) {
        curl_easy_cleanup(curl);
        if (!state->stop && alive->load()) {
            status(false, "Handshake send failed");
        }
        return;
    }

    // Read HTTP 101 response headers with bounded size (16KB)
    std::string resp_headers;
    char chunk[1024];
    bool header_complete = false;
    auto read_start = std::chrono::steady_clock::now();

    while (resp_headers.size() < 16384 && !state->stop) {
        if (std::chrono::steady_clock::now() - read_start > std::chrono::seconds(10)) {
            break;
        }

        size_t nread = 0;
        res = curl_easy_recv(curl, chunk, sizeof(chunk), &nread);
        if (res == CURLE_OK && nread > 0) {
            resp_headers.append(chunk, nread);
            if (resp_headers.find("\r\n\r\n") != std::string::npos) {
                header_complete = true;
                break;
            }
        } else if (res == CURLE_AGAIN) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        } else {
            break;
        }
    }

    std::string error_reason;
    if (!header_complete || !parse_ws_handshake_response(resp_headers, expected_accept, error_reason)) {
        if (resp_headers.find(" 403 ") != std::string::npos) {
            error_reason = "HTTP 403 Forbidden";
        } else if (resp_headers.find(" 429 ") != std::string::npos) {
            error_reason = "HTTP 429 rate_limit_exceeded";
        }
        curl_easy_cleanup(curl);
        if (!state->stop && alive->load()) {
            status(false, "Invalid WebSocket handshake response: " + error_reason);
        }
        return;
    }

    // Any remaining bytes after \r\n\r\n are part of the first WebSocket frame(s)
    std::vector<uint8_t> rx_buffer;
    size_t sep = resp_headers.find("\r\n\r\n");
    if (sep != std::string::npos && sep + 4 < resp_headers.size()) {
        const char* remaining = resp_headers.data() + sep + 4;
        size_t rem_len = resp_headers.size() - (sep + 4);
        rx_buffer.insert(rx_buffer.end(), remaining, remaining + rem_len);
    }

    curl_socket_t sockfd;
    res = curl_easy_getinfo(curl, CURLINFO_ACTIVESOCKET, &sockfd);
    if (res != CURLE_OK || sockfd == CURL_SOCKET_BAD) {
        curl_easy_cleanup(curl);
        if (!state->stop && alive->load()) {
            status(false, "Failed to retrieve active socket fd");
        }
        return;
    }

    struct wslay_event_callbacks callbacks = {
        ws_recv_callback,
        ws_send_callback,
        ws_genmask_callback,
        nullptr, // on_frame_recv_start_callback
        nullptr, // on_frame_recv_chunk_callback
        nullptr, // on_frame_recv_end_callback
        ws_on_msg_recv_callback
    };

    WslayUserData ud;
    ud.curl = curl;
    ud.rx_buffer = std::move(rx_buffer);
    ud.on_message = [state](const std::string& message) {
        std::lock_guard<std::mutex> lock(state->callback_mutex);
        if (state->alive->load()) state->message(message);
    };
    ud.alive = alive;
    ud.peer_closed = false;

    wslay_event_context_ptr ctx = nullptr;
    int r = wslay_event_context_client_init(&ctx, &callbacks, &ud);
    if (r != 0) {
        curl_easy_cleanup(curl);
        if (!state->stop && alive->load()) {
            status(false, "Failed to initialize WebSocket event context");
        }
        return;
    }
    // Bound buffered fragmented messages from an untrusted peer.
    wslay_event_config_set_max_recv_msg_length(ctx, 1024 * 1024);

    state->connected = true;
    if (alive->load()) {
        status(true, "");
    }

    const auto connected_at = std::chrono::steady_clock::now();
    ud.keepalive.last_pong_at = connected_at;
    WsKeepaliveConfig keepalive_config;

    while (!state->stop && alive->load() && !ud.peer_closed) {
        const auto now = std::chrono::steady_clock::now();
        if (ws_keepalive_should_disconnect(ud.keepalive, now, keepalive_config)) {
            break;
        }
        // Drain any pending outgoing writes
        if (wslay_event_want_write(ctx) && wslay_event_send(ctx) != 0) break;

        // Drain any coalesced or buffered incoming frames before polling
        while (!ud.rx_buffer.empty() && wslay_event_want_read(ctx)) {
            if (wslay_event_recv(ctx) != 0) break;
        }

        if (ud.peer_closed) break;

        if (ws_keepalive_should_send_ping(ud.keepalive, now, keepalive_config)) {
            struct wslay_event_msg ping_msg = {
                WSLAY_PING,
                nullptr,
                0
            };
            wslay_event_queue_msg(ctx, &ping_msg);
            wslay_event_send(ctx);
            ws_keepalive_on_ping_sent(ud.keepalive, now);
        }

        struct pollfd pfd;
        pfd.fd = sockfd;
        pfd.events = 0;
        if (wslay_event_want_read(ctx)) pfd.events |= POLLIN;
        if (wslay_event_want_write(ctx)) pfd.events |= POLLOUT;
        pfd.revents = 0;
        if (pfd.events == 0) break;

        int timeout_ms = ud.rx_buffer.empty() ? 500 : 0;
        int poll_res = poll(&pfd, 1, timeout_ms);
        if (poll_res < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (pfd.revents & POLLOUT) {
            if (wslay_event_send(ctx) != 0) break;
        }

        if (pfd.revents & POLLIN) {
            if (wslay_event_recv(ctx) != 0) break;
        }
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) break;
    }

    state->connected = false;

    // Send close frame if user initiated disconnect
    if (state->stop) {
        wslay_event_queue_close(ctx, WSLAY_CODE_NORMAL_CLOSURE, nullptr, 0);
        wslay_event_send(ctx);
    } else if (ud.peer_closed) {
        // Peer sent close frame; wslay automatically queued close response
        wslay_event_send(ctx);
    }

    wslay_event_context_free(ctx);
    curl_easy_cleanup(curl);

    if (!state->stop && alive->load()) {
        status(false, ud.peer_closed ? "Connection closed by peer" : "Connection error");
    }
}

} // namespace delivery
} // namespace pux
