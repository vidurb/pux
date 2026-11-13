#include "test_harness.hpp"
#include "../src/delivery/websocket_client.hpp"
#include "../src/api/curl_init.hpp"
#include <curl/curl.h>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <chrono>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <csignal>
#include <sys/wait.h>

#if defined(__linux__)

namespace {

constexpr int kSubprocessSeconds = 8;
constexpr int kCurlConnectSeconds = 5;
constexpr int kCurlTotalSeconds = 10;

int pick_loopback_port() {
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        close(fd);
        return 0;
    }
    socklen_t len = sizeof(addr);
    if (getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
        close(fd);
        return 0;
    }
    close(fd);
    return ntohs(addr.sin_port);
}

std::string shell_quote(const std::string& value) {
    std::string quoted = "'";
    for (char c : value) {
        if (c == '\'') quoted += "'\\''";
        else quoted += c;
    }
    quoted += "'";
    return quoted;
}

std::string run_shell_capture_bounded(const std::string& command, int timeout_seconds) {
    const std::string wrapped =
        "timeout -s TERM " + std::to_string(timeout_seconds) + "s " + command;
    std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(wrapped.c_str(), "r"), pclose);
    if (!pipe) return {};
    std::ostringstream captured;
    char buffer[512];
    while (fgets(buffer, sizeof(buffer), pipe.get()) != nullptr) {
        captured << buffer;
    }
    return captured.str();
}

std::optional<std::string> parse_s_client_alpn_protocol(const std::string& output) {
    std::istringstream lines(output);
    std::string line;
    constexpr const char* kPrefix = "ALPN protocol: ";
    while (std::getline(lines, line)) {
        if (line.rfind(kPrefix, 0) == 0) {
            std::string proto = line.substr(std::char_traits<char>::length(kPrefix));
            while (!proto.empty() && (proto.back() == '\r' || proto.back() == '\n' || proto.back() == ' ')) {
                proto.pop_back();
            }
            return proto;
        }
    }
    return std::nullopt;
}

std::string s_client_alpn_probe(int port, const std::string& client_alpn) {
    const std::string inner =
        "echo | openssl s_client -connect 127.0.0.1:" + std::to_string(port) +
        " -servername localhost -alpn " + shell_quote(client_alpn) + " -verify_quiet 2>&1";
    return run_shell_capture_bounded("sh -c " + shell_quote(inner), kSubprocessSeconds);
}

std::string read_file(const std::string& path) {
    std::ifstream input(path);
    std::ostringstream content;
    content << input.rdbuf();
    return content.str();
}

std::size_t file_size(const std::string& path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) return 0;
    return static_cast<std::size_t>(input.tellg());
}

bool trace_indicates_server_selected_h2(const std::string& trace_segment) {
    std::string lower = trace_segment;
    for (char& c : lower) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    const std::size_t h2_pos = lower.find("h2");
    if (h2_pos == std::string::npos) return false;
    const std::size_t window_start = h2_pos > 120 ? h2_pos - 120 : 0;
    const std::string window = lower.substr(window_start, 240);
    const bool alpn_context =
        window.find("alpn") != std::string::npos ||
        window.find("next proto") != std::string::npos ||
        window.find("application layer protocol") != std::string::npos;
    return alpn_context;
}

struct TrackedTlsServer {
    std::string pid_path;
    std::string trace_path;
    pid_t pid = 0;

    void load_pid() {
        std::ifstream pid_file(pid_path);
        pid_file >> pid;
    }

    void stop() {
        if (pid > 0) {
            kill(pid, SIGTERM);
            for (int i = 0; i < 20; ++i) {
                if (waitpid(pid, nullptr, WNOHANG) > 0) {
                    pid = 0;
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
            }
            if (pid > 0) {
                kill(pid, SIGKILL);
                waitpid(pid, nullptr, 0);
                pid = 0;
            }
        }
        if (!pid_path.empty()) std::remove(pid_path.c_str());
        if (!trace_path.empty()) std::remove(trace_path.c_str());
    }

    ~TrackedTlsServer() { stop(); }
};

} // namespace

TEST(websocket_tls_connect_disables_h2_alpn_selection) {
    if (std::system("which openssl >/dev/null 2>&1") != 0) {
        SKIP_TEST("openssl CLI not installed");
    }
    if (std::system("which timeout >/dev/null 2>&1") != 0) {
        SKIP_TEST("timeout utility not installed");
    }

    const char* storage = std::getenv("BB_THREAD_STORAGE");
    std::string dir = storage ? storage : "/tmp";
    const std::string cert = dir + "/pux_test_cert.pem";
    const std::string key = dir + "/pux_test_key.pem";
    TrackedTlsServer server;
    server.pid_path = dir + "/pux_alpn_server.pid";
    server.trace_path = dir + "/pux_alpn_server.trace";
    const std::string gen =
        "openssl req -x509 -newkey rsa:2048 -keyout '" + key + "' -out '" + cert +
        "' -days 1 -nodes -subj /CN=localhost 2>/dev/null";
    if (std::system(gen.c_str()) != 0) {
        SKIP_TEST("failed to generate test TLS certificate");
    }

    const int port = pick_loopback_port();
    if (port == 0) {
        SKIP_TEST("failed to acquire ephemeral port");
    }

    std::remove(server.trace_path.c_str());
    std::remove(server.pid_path.c_str());
    std::string launch =
        "timeout -s TERM " + std::to_string(kSubprocessSeconds + 30) + "s sh -c 'openssl s_server -accept 127.0.0.1:" +
        std::to_string(port) + " -cert " + shell_quote(cert) + " -key " + shell_quote(key) +
        " -alpn h2,http/1.1 -www -trace >" + shell_quote(server.trace_path) +
        " 2>&1 & echo $! >" + shell_quote(server.pid_path) + "'";
    if (std::system(launch.c_str()) != 0) {
        SKIP_TEST("failed to launch openssl s_server");
    }
    server.load_pid();
    std::this_thread::sleep_for(std::chrono::milliseconds(300));

    const std::string h2_probe = s_client_alpn_probe(port, "h2");
    const auto h2_positive = parse_s_client_alpn_protocol(h2_probe);
    ASSERT_TRUE(h2_positive.has_value());
    ASSERT_EQ(*h2_positive, "h2");

    const std::size_t trace_before_curl = file_size(server.trace_path);

    pux::api::ensure_curl_initialized();
    CURL* curl = curl_easy_init();
    ASSERT_TRUE(curl != nullptr);
    const std::string url = "https://127.0.0.1:" + std::to_string(port) + "/";
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_CONNECT_ONLY, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, static_cast<long>(kCurlConnectSeconds));
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, static_cast<long>(kCurlTotalSeconds));
    pux::delivery::apply_ws_connect_curl_options(curl);
    const CURLcode res = curl_easy_perform(curl);
    ASSERT_EQ(res, CURLE_OK);

    const std::string trace_after = read_file(server.trace_path);
    ASSERT_TRUE(trace_after.size() > trace_before_curl);
    const std::string curl_segment = trace_after.substr(trace_before_curl);
    ASSERT_FALSE(trace_indicates_server_selected_h2(curl_segment));

    curl_easy_cleanup(curl);

    const auto http11_probe = parse_s_client_alpn_protocol(s_client_alpn_probe(port, "http/1.1"));
    ASSERT_TRUE(http11_probe.has_value());
    ASSERT_EQ(*http11_probe, "http/1.1");
}

#endif
