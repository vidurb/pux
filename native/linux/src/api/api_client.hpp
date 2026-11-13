#pragma once

#include <string>
#include <vector>
#include <memory>
#include <stdexcept>
#include "../vendor/json.hpp"

namespace pux {
namespace api {

class ApiException : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class RecordNotFoundException : public ApiException {
public:
    RecordNotFoundException() : ApiException("Relay not found on the server") {}
};

class TooManyDevicesException : public ApiException {
public:
    TooManyDevicesException() : ApiException("This relay already has the maximum number of devices") {}
};

class RateLimitedException : public ApiException {
public:
    RateLimitedException() : ApiException("The server is rate limiting requests") {}
};

class NoDevicesException : public ApiException {
public:
    NoDevicesException() : ApiException("No device is registered on this relay yet") {}
};

struct PendingDelivery {
    std::string delivery_id;
    nlohmann::json envelope;
};

struct TestCode {
    std::string otp;
    int devices = 0;
};

enum class ServerHealthState {
    Reachable,
    Unreachable,
    ServerError
};

struct ServerHealth {
    ServerHealthState state;
    std::string reason;
};

struct HttpResponse {
    long status_code = 0;
    std::string body;
};

class HttpTransport {
public:
    virtual ~HttpTransport() = default;
    virtual HttpResponse request(
        const std::string& method,
        const std::string& url,
        const std::vector<std::string>& headers,
        const std::string& body,
        long timeout_seconds = 15
    ) = 0;
};

class CurlHttpTransport : public HttpTransport {
public:
    CurlHttpTransport();
    ~CurlHttpTransport() override;

    HttpResponse request(
        const std::string& method,
        const std::string& url,
        const std::vector<std::string>& headers,
        const std::string& body,
        long timeout_seconds = 15
    ) override;
};

class ApiClient {
public:
    static constexpr size_t kPendingPageSize = 50;

    explicit ApiClient(std::shared_ptr<HttpTransport> transport = nullptr);

    void set_transport(std::shared_ptr<HttpTransport> transport) {
        transport_ = std::move(transport);
    }

    struct RecordCreationResult {
        std::string record_id;
        std::string inbox_address;
    };

    RecordCreationResult create_record(const std::string& server_url, const std::string& public_key);

    std::string register_device(
        const std::string& server_url,
        const std::string& record_id,
        const std::string& push_token,
        const std::string& platform = "desktop",
        const std::string& replaces_device_id = ""
    );

    void delete_device(
        const std::string& server_url,
        const std::string& record_id,
        const std::string& device_id
    );

    void delete_record(
        const std::string& server_url,
        const std::string& record_id
    );

    std::vector<PendingDelivery> list_pending_deliveries(
        const std::string& server_url,
        const std::string& record_id
    );

    void ack_delivery(
        const std::string& server_url,
        const std::string& record_id,
        const std::string& delivery_id
    );

    TestCode send_test_code(
        const std::string& server_url,
        const std::string& record_id
    );

    ServerHealth check_health(const std::string& server_url);

    static std::string delivery_websocket_url(const std::string& server_url);

private:
    std::shared_ptr<HttpTransport> transport_;

    void check_response(const HttpResponse& resp, const std::string& action);
    std::string extract_error_code(const std::string& body);
};

} // namespace api
} // namespace pux
