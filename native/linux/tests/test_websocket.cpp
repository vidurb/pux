#include "test_harness.hpp"
#include "../src/delivery/websocket_client.hpp"
#include "../src/api/curl_init.hpp"
#include <curl/curl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <thread>
#include <chrono>
#include <atomic>
#include <cstring>
#include <iostream>
#include <mutex>

namespace {

class SharedString {
    mutable std::mutex mutex_;
    std::string value_;
public:
    void operator=(const std::string& value) { std::lock_guard<std::mutex> lock(mutex_); value_ = value; }
    std::string get() const { std::lock_guard<std::mutex> lock(mutex_); return value_; }
    bool empty() const { return get().empty(); }
};

// Helper class for local TCP WebSocket integration test server
class LocalWsServer {
public:
    int server_fd = -1;
    int port = 0;
    std::thread server_thread;

    LocalWsServer() {
        server_fd = socket(AF_INET, SOCK_STREAM, 0);
        int opt = 1;
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0; // ephemeral port

        bind(server_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
        socklen_t len = sizeof(addr);
        getsockname(server_fd, reinterpret_cast<sockaddr*>(&addr), &len);
        port = ntohs(addr.sin_port);
        listen(server_fd, 1);
    }

    ~LocalWsServer() {
        if (server_fd >= 0) {
            close(server_fd);
        }
        if (server_thread.joinable()) {
            server_thread.join();
        }
    }
};

} // namespace

TEST(websocket_sec_ws_accept_hash_validation) {
    // RFC 6455 Section 1.3 standard test vector:
    // Key: "dGhlIHNhbXBsZSBub25jZQ==" -> Accept: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    std::string key = "dGhlIHNhbXBsZSBub25jZQ==";
    std::string accept = pux::delivery::compute_sec_ws_accept(key);
    ASSERT_EQ(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
}

TEST(websocket_handshake_request_builder) {
    std::string host = "pux.vidur.xyz:8443";
    std::string path = "/ws/delivery";
    std::string token = "11111111-2222-3333-4444-555555555555";
    std::string sec_key = "dGhlIHNhbXBsZSBub25jZQ==";

    std::string req = pux::delivery::build_ws_handshake_request(host, path, token, sec_key);
    ASSERT_TRUE(req.find("GET /ws/delivery HTTP/1.1\r\n") != std::string::npos);
    ASSERT_TRUE(req.find("Host: pux.vidur.xyz:8443\r\n") != std::string::npos);
    ASSERT_TRUE(req.find("Upgrade: websocket\r\n") != std::string::npos);
    ASSERT_TRUE(req.find("Connection: Upgrade\r\n") != std::string::npos);
    ASSERT_TRUE(req.find("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n") != std::string::npos);
    ASSERT_TRUE(req.find("x-pux-token: 11111111-2222-3333-4444-555555555555\r\n") != std::string::npos);
}

TEST(websocket_handshake_response_parser_validates_rfc6455) {
    std::string expected_accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
    std::string err;

    // 1. Valid handshake
    std::string valid_resp =
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    ASSERT_TRUE(pux::delivery::parse_ws_handshake_response(valid_resp, expected_accept, err));

    // 2. Invalid 101: raw 101 with no headers (Terra probe finding 1)
    std::string raw_101 = "HTTP/1.1 101 Switching Protocols\r\n\r\n";
    ASSERT_FALSE(pux::delivery::parse_ws_handshake_response(raw_101, expected_accept, err));
    ASSERT_TRUE(err.find("Missing or invalid Upgrade header") != std::string::npos);

    // 3. Missing Connection header
    std::string missing_conn =
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    ASSERT_FALSE(pux::delivery::parse_ws_handshake_response(missing_conn, expected_accept, err));
    ASSERT_TRUE(err.find("Missing or invalid Connection header") != std::string::npos);

    // 4. Mismatch Sec-WebSocket-Accept
    std::string bad_accept =
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: wronghash12345=\r\n\r\n";
    ASSERT_FALSE(pux::delivery::parse_ws_handshake_response(bad_accept, expected_accept, err));
    ASSERT_TRUE(err.find("Sec-WebSocket-Accept mismatch") != std::string::npos);

    // 5. Non-101 error response (403, 500)
    std::string forbidden = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
    ASSERT_FALSE(pux::delivery::parse_ws_handshake_response(forbidden, expected_accept, err));
    ASSERT_TRUE(err.find("Expected HTTP 101") != std::string::npos);
}

TEST(websocket_curl_connect_applies_http11_options) {
    pux::api::ensure_curl_initialized();
    CURL* curl = curl_easy_init();
    ASSERT_TRUE(curl != nullptr);
    pux::delivery::apply_ws_connect_curl_options(curl);
    curl_easy_cleanup(curl);
}

TEST(websocket_live_socket_handshake_and_message_delivery) {
    LocalWsServer server;

    server.server_thread = std::thread([&server]() {
        int client_fd = accept(server.server_fd, nullptr, nullptr);
        if (client_fd < 0) return;

        char req_buf[4096];
        ssize_t n = recv(client_fd, req_buf, sizeof(req_buf) - 1, 0);
        if (n <= 0) { close(client_fd); return; }
        req_buf[n] = '\0';
        std::string req(req_buf);

        // Find Sec-WebSocket-Key
        size_t key_pos = req.find("Sec-WebSocket-Key: ");
        std::string accept_key;
        if (key_pos != std::string::npos) {
            size_t end_line = req.find("\r\n", key_pos);
            std::string key = req.substr(key_pos + 19, end_line - (key_pos + 19));
            accept_key = pux::delivery::compute_sec_ws_accept(key);
        }

        std::string resp =
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: " + accept_key + "\r\n\r\n";
        send(client_fd, resp.data(), resp.size(), 0);

        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        // Send unmasked text frame from server: opcode 0x1, length 5, payload "hello"
        std::string frame = "\x81\x05hello";
        send(client_fd, frame.data(), frame.size(), 0);

        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        close(client_fd);
    });

    std::atomic<bool> connected{false};
    SharedString received_msg;

    pux::delivery::WebSocketClient client(
        [&received_msg](const std::string& msg) {
            received_msg = msg;
        },
        [&connected](bool ok, const std::string& /*err*/) {
            connected = ok;
        }
    );

    std::string url = "ws://127.0.0.1:" + std::to_string(server.port) + "/ws/delivery";
    client.connect(url, "test-record-id");

    for (int i = 0; i < 50 && received_msg.empty(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    ASSERT_TRUE(connected.load());
    ASSERT_EQ(received_msg.get(), "hello");

    client.disconnect();
}

TEST(websocket_live_socket_rejects_invalid_handshake) {
    LocalWsServer server;

    server.server_thread = std::thread([&server]() {
        int client_fd = accept(server.server_fd, nullptr, nullptr);
        if (client_fd < 0) return;

        char req_buf[2048];
        recv(client_fd, req_buf, sizeof(req_buf), 0);

        // Send invalid 101 response without upgrade headers (Terra probe finding 1)
        std::string resp = "HTTP/1.1 101 Switching Protocols\r\n\r\n";
        send(client_fd, resp.data(), resp.size(), 0);

        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        close(client_fd);
    });

    std::atomic<bool> connected{false};
    SharedString error_msg;

    pux::delivery::WebSocketClient client(
        [](const std::string&) {},
        [&connected, &error_msg](bool ok, const std::string& err) {
            connected = ok;
            error_msg = err;
        }
    );

    std::string url = "ws://127.0.0.1:" + std::to_string(server.port) + "/ws/delivery";
    client.connect(url, "test-record-id");

    for (int i = 0; i < 50 && error_msg.empty(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    ASSERT_FALSE(connected.load());
    ASSERT_TRUE(error_msg.get().find("Invalid WebSocket handshake response") != std::string::npos);

    client.disconnect();
}

TEST(websocket_live_socket_coalesced_handshake_and_frames) {
    LocalWsServer server;

    server.server_thread = std::thread([&server]() {
        int client_fd = accept(server.server_fd, nullptr, nullptr);
        if (client_fd < 0) return;

        char req_buf[4096];
        ssize_t n = recv(client_fd, req_buf, sizeof(req_buf) - 1, 0);
        if (n <= 0) { close(client_fd); return; }
        req_buf[n] = '\0';
        std::string req(req_buf);

        size_t key_pos = req.find("Sec-WebSocket-Key: ");
        std::string accept_key;
        if (key_pos != std::string::npos) {
            size_t end_line = req.find("\r\n", key_pos);
            std::string key = req.substr(key_pos + 19, end_line - (key_pos + 19));
            accept_key = pux::delivery::compute_sec_ws_accept(key);
        }

        // Coalesce HTTP 101 response AND text frame \x81\x02hi in a single write (Terra probe finding 2)
        std::string coalesced =
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: " + accept_key + "\r\n\r\n\x81\x02hi";

        send(client_fd, coalesced.data(), coalesced.size(), 0);

        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        close(client_fd);
    });

    SharedString received_msg;
    pux::delivery::WebSocketClient client(
        [&received_msg](const std::string& msg) {
            received_msg = msg;
        },
        [](bool, const std::string&) {}
    );

    std::string url = "ws://127.0.0.1:" + std::to_string(server.port) + "/ws/delivery";
    client.connect(url, "test-record-id");

    for (int i = 0; i < 50 && received_msg.empty(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    ASSERT_EQ(received_msg.get(), "hi");

    client.disconnect();
}

TEST(websocket_live_socket_fragmented_frames_reassembled) {
    LocalWsServer server;

    server.server_thread = std::thread([&server]() {
        int client_fd = accept(server.server_fd, nullptr, nullptr);
        if (client_fd < 0) return;

        char req_buf[4096];
        ssize_t n = recv(client_fd, req_buf, sizeof(req_buf) - 1, 0);
        if (n <= 0) { close(client_fd); return; }
        req_buf[n] = '\0';
        std::string req(req_buf);

        size_t key_pos = req.find("Sec-WebSocket-Key: ");
        std::string accept_key;
        if (key_pos != std::string::npos) {
            size_t end_line = req.find("\r\n", key_pos);
            std::string key = req.substr(key_pos + 19, end_line - (key_pos + 19));
            accept_key = pux::delivery::compute_sec_ws_accept(key);
        }

        std::string resp =
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: " + accept_key + "\r\n\r\n";
        send(client_fd, resp.data(), resp.size(), 0);

        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        // RFC 6455 fragmentation:
        // Frame 1: FIN=0, Opcode=Text (0x01), len=6, payload "hello "
        std::string frame1 = std::string("\x01\x06", 2) + "hello ";
        send(client_fd, frame1.data(), frame1.size(), 0);

        std::this_thread::sleep_for(std::chrono::milliseconds(50));

        // Frame 2: FIN=1 (0x80), Opcode=Continuation (0x00), len=5, payload "world"
        std::string frame2 = std::string("\x80\x05", 2) + "world";
        send(client_fd, frame2.data(), frame2.size(), 0);

        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        close(client_fd);
    });

    SharedString received_msg;
    pux::delivery::WebSocketClient client(
        [&received_msg](const std::string& msg) {
            received_msg = msg;
        },
        [](bool, const std::string&) {}
    );

    std::string url = "ws://127.0.0.1:" + std::to_string(server.port) + "/ws/delivery";
    client.connect(url, "test-record-id");

    for (int i = 0; i < 50 && received_msg.empty(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    ASSERT_EQ(received_msg.get(), "hello world");

    client.disconnect();
}

TEST(websocket_live_socket_clean_peer_close_triggers_reconnect) {
    LocalWsServer server;

    server.server_thread = std::thread([&server]() {
        int client_fd = accept(server.server_fd, nullptr, nullptr);
        if (client_fd < 0) return;

        char req_buf[4096];
        ssize_t n = recv(client_fd, req_buf, sizeof(req_buf) - 1, 0);
        if (n <= 0) { close(client_fd); return; }
        req_buf[n] = '\0';
        std::string req(req_buf);

        size_t key_pos = req.find("Sec-WebSocket-Key: ");
        std::string accept_key;
        if (key_pos != std::string::npos) {
            size_t end_line = req.find("\r\n", key_pos);
            std::string key = req.substr(key_pos + 19, end_line - (key_pos + 19));
            accept_key = pux::delivery::compute_sec_ws_accept(key);
        }

        std::string resp =
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: " + accept_key + "\r\n\r\n";
        send(client_fd, resp.data(), resp.size(), 0);

        std::this_thread::sleep_for(std::chrono::milliseconds(200));

        // Clean server close frame: \x88\x00 (Terra probe finding 2)
        std::string close_frame = std::string("\x88\x00", 2);
        send(client_fd, close_frame.data(), close_frame.size(), 0);

        // Read client's close response frame
        char close_ack[64];
        recv(client_fd, close_ack, sizeof(close_ack), 0);

        close(client_fd);
    });

    std::atomic<bool> was_connected{false};
    std::atomic<bool> peer_closed_notified{false};
    std::string final_status_err;

    pux::delivery::WebSocketClient client(
        [](const std::string&) {},
        [&was_connected, &peer_closed_notified, &final_status_err](bool ok, const std::string& err) {
            if (ok) {
                was_connected = true;
            } else {
                final_status_err = err;
                peer_closed_notified = true;
            }
        }
    );

    std::string url = "ws://127.0.0.1:" + std::to_string(server.port) + "/ws/delivery";
    client.connect(url, "test-record-id");

    for (int i = 0; i < 50 && !peer_closed_notified.load(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    ASSERT_TRUE(was_connected.load());
    ASSERT_TRUE(peer_closed_notified.load());
    ASSERT_TRUE(final_status_err.find("Connection closed by peer") != std::string::npos);

    client.disconnect();
}

TEST(websocket_live_socket_automatic_pong_to_ping) {
    LocalWsServer server;
    std::atomic<bool> pong_received{false};

    server.server_thread = std::thread([&server, &pong_received]() {
        int client_fd = accept(server.server_fd, nullptr, nullptr);
        if (client_fd < 0) return;

        char req_buf[4096];
        ssize_t n = recv(client_fd, req_buf, sizeof(req_buf) - 1, 0);
        if (n <= 0) { close(client_fd); return; }
        req_buf[n] = '\0';
        std::string req(req_buf);

        size_t key_pos = req.find("Sec-WebSocket-Key: ");
        std::string accept_key;
        if (key_pos != std::string::npos) {
            size_t end_line = req.find("\r\n", key_pos);
            std::string key = req.substr(key_pos + 19, end_line - (key_pos + 19));
            accept_key = pux::delivery::compute_sec_ws_accept(key);
        }

        std::string resp =
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: " + accept_key + "\r\n\r\n";
        send(client_fd, resp.data(), resp.size(), 0);

        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        // Server sends Ping frame: opcode 0x9, len 4, payload "ping"
        std::string ping_frame = std::string("\x89\x04", 2) + "ping";
        send(client_fd, ping_frame.data(), ping_frame.size(), 0);

        // Read client response: must be Pong frame (opcode 0xA)
        uint8_t pong_buf[64];
        ssize_t pr = recv(client_fd, pong_buf, sizeof(pong_buf), 0);
        if (pr >= 2) {
            // Client frames are masked: b0 & 0x0F should be 0x0A (Pong)
            pong_received = (pong_buf[0] & 0x0F) == 0x0A && (pong_buf[1] & 0x80);
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        close(client_fd);
    });

    std::atomic<bool> connected{false};
    pux::delivery::WebSocketClient client(
        [](const std::string&) {},
        [&connected](bool ok, const std::string&) {
            connected = ok;
        }
    );

    std::string url = "ws://127.0.0.1:" + std::to_string(server.port) + "/ws/delivery";
    client.connect(url, "test-record-id");

    for (int i = 0; i < 30 && !connected.load(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    ASSERT_TRUE(connected.load());

    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    client.disconnect();
    ASSERT_TRUE(pong_received.load());
}

TEST(websocket_disconnect_does_not_wait_for_slow_handshake) {
    LocalWsServer server;
    std::atomic<bool> accepted{false};
    server.server_thread = std::thread([&]() {
        int fd = accept(server.server_fd, nullptr, nullptr);
        if (fd < 0) return;
        accepted = true;
        std::this_thread::sleep_for(std::chrono::milliseconds(700));
        close(fd);
    });
    std::atomic<int> callbacks{0};
    pux::delivery::WebSocketClient client([](const std::string&) {},
        [&](bool, const std::string&) { ++callbacks; });
    client.connect("ws://127.0.0.1:" + std::to_string(server.port) + "/", "test");
    for (int i = 0; i < 200 && !accepted; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    auto start = std::chrono::steady_clock::now();
    client.disconnect();
    auto elapsed = std::chrono::steady_clock::now() - start;
    ASSERT_TRUE(accepted.load());
    ASSERT_TRUE(elapsed < std::chrono::milliseconds(200));
    server.server_thread.join();
    ASSERT_EQ(callbacks.load(), 0);
}
