#pragma once
#include <functional>
#include <string>
#include <exception>

namespace pux::ui {
enum class RemovalResult { Success, Retry, Cancel, ForgetLocally };

struct RemovalAttempt { bool succeeded; std::string error; };
inline RemovalAttempt attempt_removal(const std::function<void()>& call) {
    try { call(); return {true, {}}; }
    catch (const std::exception& e) { return {false, e.what()}; }
    catch (...) { return {false, "Unknown network error"}; }
}

// Called after the server attempt or the user's choice in the failure dialog.
inline void finish_removal(RemovalResult result, const std::function<void()>& clear,
                           const std::function<void()>& resume, const std::function<void()>& retry) {
    switch (result) {
    case RemovalResult::Success:
    case RemovalResult::ForgetLocally: clear(); break;
    case RemovalResult::Cancel: resume(); break;
    case RemovalResult::Retry: retry(); break;
    }
}
}
