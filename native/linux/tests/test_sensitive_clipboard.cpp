#include "test_harness.hpp"
#include "../src/clipboard/sensitive_clipboard.hpp"

TEST(sensitive_clipboard_copies_and_clears_if_unchanged) {
    std::string simulated_clipboard;

    auto setter = [&simulated_clipboard](const std::string& text) {
        simulated_clipboard = text;
    };
    auto getter = [&simulated_clipboard]() -> std::string {
        return simulated_clipboard;
    };

    pux::clipboard::SensitiveClipboard clip(setter, getter);

    clip.copy("secret-otp-123456");
    ASSERT_EQ(simulated_clipboard, "secret-otp-123456");

    // Simulating timer firing: clipboard hasn't changed -> cleared
    clip.clear_if_unchanged();
    ASSERT_EQ(simulated_clipboard, "");
}

TEST(sensitive_clipboard_preserves_external_changes) {
    std::string simulated_clipboard;

    auto setter = [&simulated_clipboard](const std::string& text) {
        simulated_clipboard = text;
    };
    auto getter = [&simulated_clipboard]() -> std::string {
        return simulated_clipboard;
    };

    pux::clipboard::SensitiveClipboard clip(setter, getter);

    clip.copy("secret-otp-999");
    ASSERT_EQ(simulated_clipboard, "secret-otp-999");

    // User copies something else externally
    simulated_clipboard = "some other text";

    // Timer fires: should NOT overwrite the user's new clipboard contents
    clip.clear_if_unchanged();
    ASSERT_EQ(simulated_clipboard, "some other text");
}
