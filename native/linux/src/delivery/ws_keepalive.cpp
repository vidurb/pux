#include "ws_keepalive.hpp"

namespace pux::delivery {

bool ws_keepalive_should_disconnect(
    const WsKeepaliveState& state,
    std::chrono::steady_clock::time_point now,
    const WsKeepaliveConfig& config
) {
    return state.awaiting_pong && (now - state.ping_sent_at) > config.pong_deadline;
}

bool ws_keepalive_should_send_ping(
    const WsKeepaliveState& state,
    std::chrono::steady_clock::time_point now,
    const WsKeepaliveConfig& config
) {
    if (state.awaiting_pong) {
        return false;
    }
    return (now - state.last_pong_at) >= config.ping_interval;
}

void ws_keepalive_on_ping_sent(WsKeepaliveState& state, std::chrono::steady_clock::time_point now) {
    state.ping_sent_at = now;
    state.awaiting_pong = true;
}

void ws_keepalive_on_pong(WsKeepaliveState& state, std::chrono::steady_clock::time_point now) {
    state.last_pong_at = now;
    state.awaiting_pong = false;
}

} // namespace pux::delivery
