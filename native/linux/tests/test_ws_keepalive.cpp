#include "test_harness.hpp"
#include "../src/delivery/ws_keepalive.hpp"

#include <chrono>

TEST(ws_keepalive_does_not_send_ping_while_awaiting_pong) {
    pux::delivery::WsKeepaliveState state;
    pux::delivery::WsKeepaliveConfig config;
    config.ping_interval = std::chrono::milliseconds(30);
    config.pong_deadline = std::chrono::milliseconds(45);

    const auto t0 = std::chrono::steady_clock::now();
    state.last_pong_at = t0;
    pux::delivery::ws_keepalive_on_ping_sent(state, t0 + std::chrono::milliseconds(30));

    const auto t1 = t0 + std::chrono::milliseconds(60);
    ASSERT_FALSE(pux::delivery::ws_keepalive_should_send_ping(state, t1, config));
    ASSERT_FALSE(pux::delivery::ws_keepalive_should_disconnect(state, t1, config));
}

TEST(ws_keepalive_times_out_silent_peer_without_ping_reset) {
    pux::delivery::WsKeepaliveState state;
    pux::delivery::WsKeepaliveConfig config;
    config.ping_interval = std::chrono::milliseconds(30);
    config.pong_deadline = std::chrono::milliseconds(45);

    const auto t0 = std::chrono::steady_clock::now();
    state.last_pong_at = t0;
    pux::delivery::ws_keepalive_on_ping_sent(state, t0 + std::chrono::milliseconds(30));

    const auto before_deadline = t0 + std::chrono::milliseconds(74);
    ASSERT_FALSE(pux::delivery::ws_keepalive_should_disconnect(state, before_deadline, config));

    const auto after_deadline = t0 + std::chrono::milliseconds(76);
    ASSERT_TRUE(pux::delivery::ws_keepalive_should_disconnect(state, after_deadline, config));

    ASSERT_FALSE(pux::delivery::ws_keepalive_should_send_ping(state, after_deadline, config));
}

TEST(ws_keepalive_resumes_ping_after_pong) {
    pux::delivery::WsKeepaliveState state;
    pux::delivery::WsKeepaliveConfig config;
    config.ping_interval = std::chrono::milliseconds(30);
    config.pong_deadline = std::chrono::milliseconds(45);

    const auto t0 = std::chrono::steady_clock::now();
    state.last_pong_at = t0;
    pux::delivery::ws_keepalive_on_ping_sent(state, t0 + std::chrono::milliseconds(30));
    pux::delivery::ws_keepalive_on_pong(state, t0 + std::chrono::milliseconds(40));

    ASSERT_FALSE(pux::delivery::ws_keepalive_should_disconnect(state, t0 + std::chrono::milliseconds(50), config));
    ASSERT_FALSE(pux::delivery::ws_keepalive_should_send_ping(state, t0 + std::chrono::milliseconds(65), config));
    ASSERT_TRUE(pux::delivery::ws_keepalive_should_send_ping(state, t0 + std::chrono::milliseconds(71), config));
}
