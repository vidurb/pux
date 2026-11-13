#pragma once
#include <memory>
#include <utility>

namespace pux::ui {
struct DeliveryStartState {
    bool window_alive;
    bool storage_loading;
    bool storage_error;
    bool removal_in_progress;
    bool recovery_pending;
    bool enrolled;
    bool stopped;
};

template<class Start>
bool start_delivery_if_ready(const DeliveryStartState& s, Start&& start) {
    if (!s.window_alive || s.storage_loading || s.storage_error || s.removal_in_progress ||
        s.recovery_pending || !s.enrolled || !s.stopped) return false;
    std::forward<Start>(start)();
    return true;
}

template<class Window, class IsLive, class Factory>
bool ensure_live_window(std::unique_ptr<Window>& window, IsLive&& live, Factory&& factory) {
    if (window && live(*window)) return false;
    window.reset();
    window = factory();
    return true;
}
}
