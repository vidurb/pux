#pragma once

#include <chrono>

namespace pux::delivery {

struct WsKeepaliveConfig {
    std::chrono::steady_clock::duration ping_interval{std::chrono::seconds(30)};
    std::chrono::steady_clock::duration pong_deadline{std::chrono::seconds(45)};
};

struct WsKeepaliveState {
    std::chrono::steady_clock::time_point last_pong_at{};
    std::chrono::steady_clock::time_point ping_sent_at{};
    bool awaiting_pong = false;
};

// Returns true when the connection should be closed due to pong timeout.
bool ws_keepalive_should_disconnect(
    const WsKeepaliveState& state,
    std::chrono::steady_clock::time_point now,
    const WsKeepaliveConfig& config
);

// Returns true when a new ping should be queued (only while not awaiting pong).
bool ws_keepalive_should_send_ping(
    const WsKeepaliveState& state,
    std::chrono::steady_clock::time_point now,
    const WsKeepaliveConfig& config
);

// Call when a ping frame is queued for send.
void ws_keepalive_on_ping_sent(WsKeepaliveState& state, std::chrono::steady_clock::time_point now);

// Call when a pong frame is received.
void ws_keepalive_on_pong(WsKeepaliveState& state, std::chrono::steady_clock::time_point now);

} // namespace pux::delivery
