#pragma once

#include <string>
#include <chrono>
#include <memory>
#include <functional>

namespace pux {
namespace clipboard {

class SensitiveClipboard {
public:
    static constexpr std::chrono::seconds kClearAfter{60};

    using ClipboardSetter = std::function<void(const std::string& text)>;
    using ClipboardGetter = std::function<std::string()>;

    explicit SensitiveClipboard(
        ClipboardSetter setter = nullptr,
        ClipboardGetter getter = nullptr
    );
    ~SensitiveClipboard();

    static SensitiveClipboard& instance();

    void copy(const std::string& text);
    void clear_if_unchanged();
    void cancel();

    const std::string& last_copied() const { return last_copied_; }

private:
    ClipboardSetter setter_;
    ClipboardGetter getter_;
    std::string last_copied_;
    uint32_t timer_id_ = 0;
};

} // namespace clipboard
} // namespace pux
