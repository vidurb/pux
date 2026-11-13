#include "api_client.hpp"
#include "curl_init.hpp"
#include <curl/curl.h>
#include <sstream>
#include <cstdlib>

namespace pux {
namespace api {

namespace {

void assert_linux_test_network_allowed(const std::string& url) {
    if (!std::getenv("PUX_LINUX_TEST_NO_NETWORK")) {
        return;
    }
    const bool local =
        url.find("127.0.0.1") != std::string::npos || url.find("localhost") != std::string::npos;
    if (!local) {
        throw ApiException("External HTTP blocked during linux tests: " + url);
    }
}

size_t curl_write_cb(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t total = size * nmemb;
    auto* s = static_cast<std::string*>(userp);
    s->append(static_cast<char*>(contents), total);
    return total;
}

} // namespace

CurlHttpTransport::CurlHttpTransport() {
    ensure_curl_initialized();
}

CurlHttpTransport::~CurlHttpTransport() {
    // Note: global cleanup omitted or called on process exit
}

HttpResponse CurlHttpTransport::request(
    const std::string& method,
    const std::string& url,
    const std::vector<std::string>& headers,
    const std::string& body,
    long timeout_seconds
) {
    assert_linux_test_network_allowed(url);
    CURL* curl = curl_easy_init();
    if (!curl) {
        throw ApiException("Failed to initialize cURL handle");
    }

    std::string response_body;
    curl_slist* chunk = nullptr;
    for (const auto& h : headers) {
        chunk = curl_slist_append(chunk, h.c_str());
    }

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, chunk);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response_body);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_seconds);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

    if (method == "POST") {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
    } else if (method == "DELETE") {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "DELETE");
    } else if (method == "GET") {
        curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
    }

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    if (chunk) {
        curl_slist_free_all(chunk);
    }
    curl_easy_cleanup(curl);

    if (res != CURLE_OK) {
        throw ApiException(std::string("HTTP request failed: ") + curl_easy_strerror(res));
    }

    return HttpResponse{http_code, response_body};
}

ApiClient::ApiClient(std::shared_ptr<HttpTransport> transport)
    : transport_(transport ? std::move(transport) : std::make_shared<CurlHttpTransport>()) {}

std::string ApiClient::extract_error_code(const std::string& body) {
    try {
        auto j = nlohmann::json::parse(body);
        if (j.is_object() && j.contains("error") && j["error"].is_string()) {
            return j["error"].get<std::string>();
        }
    } catch (...) {}
    return "";
}

void ApiClient::check_response(const HttpResponse& resp, const std::string& action) {
    if (resp.status_code == 429) {
        throw RateLimitedException();
    }
    if (resp.status_code < 200 || resp.status_code >= 300) {
        std::string detail = resp.body.empty() ? "(empty body)" : resp.body;
        throw ApiException(action + " failed (" + std::to_string(resp.status_code) + "): " + detail);
    }
}

ApiClient::RecordCreationResult ApiClient::create_record(
    const std::string& server_url,
    const std::string& public_key
) {
    std::string url = server_url + "/api/v1/records";
    std::vector<std::string> headers = {"content-type: application/json"};
    nlohmann::json req_body = {{"public_key", public_key}};

    HttpResponse resp = transport_->request("POST", url, headers, req_body.dump());
    check_response(resp, "Record creation");

    try {
        auto j = nlohmann::json::parse(resp.body);
        if (!j.contains("record_id") || !j.contains("inbox_address")) {
            throw ApiException("Record creation returned an incomplete response");
        }
        return RecordCreationResult{
            j["record_id"].get<std::string>(),
            j["inbox_address"].get<std::string>()
        };
    } catch (const std::exception& e) {
        throw ApiException(std::string("Failed to parse record creation response: ") + e.what());
    }
}

std::string ApiClient::register_device(
    const std::string& server_url,
    const std::string& record_id,
    const std::string& push_token,
    const std::string& platform,
    const std::string& replaces_device_id
) {
    std::string url = server_url + "/api/v1/record/devices";
    std::vector<std::string> headers = {
        "authorization: Bearer " + record_id,
        "content-type: application/json"
    };

    nlohmann::json req_body = {
        {"push_token", push_token},
        {"platform", platform}
    };
    if (!replaces_device_id.empty()) {
        req_body["device_id"] = replaces_device_id;
    }

    HttpResponse resp = transport_->request("POST", url, headers, req_body.dump());

    if (resp.status_code == 401 || resp.status_code == 404) {
        throw RecordNotFoundException();
    }
    if (resp.status_code == 422 && extract_error_code(resp.body) == "too_many_devices") {
        throw TooManyDevicesException();
    }
    check_response(resp, "Device registration");

    try {
        auto j = nlohmann::json::parse(resp.body);
        if (j.is_object() && j.contains("device_id") && j["device_id"].is_string()) {
            auto id = j["device_id"].get<std::string>();
            if (!id.empty()) return id;
        }
    } catch (...) {}
    throw ApiException("Device registration returned an invalid device ID");
}

void ApiClient::delete_device(
    const std::string& server_url,
    const std::string& record_id,
    const std::string& device_id
) {
    std::string url = server_url + "/api/v1/record/devices/" + device_id;
    std::vector<std::string> headers = {"authorization: Bearer " + record_id};

    HttpResponse resp = transport_->request("DELETE", url, headers, "");
    if (resp.status_code == 401 || resp.status_code == 404) {
        return; // Already deleted
    }
    check_response(resp, "Device removal");
}

void ApiClient::delete_record(
    const std::string& server_url,
    const std::string& record_id
) {
    std::string url = server_url + "/api/v1/record";
    std::vector<std::string> headers = {"authorization: Bearer " + record_id};

    HttpResponse resp = transport_->request("DELETE", url, headers, "");
    if (resp.status_code == 401 || resp.status_code == 404) {
        return; // Already deleted
    }
    check_response(resp, "Relay deletion");
}

std::vector<PendingDelivery> ApiClient::list_pending_deliveries(
    const std::string& server_url,
    const std::string& record_id
) {
    std::string url = server_url + "/api/v1/record/deliveries";
    std::vector<std::string> headers = {"authorization: Bearer " + record_id};

    HttpResponse resp = transport_->request("GET", url, headers, "");
    if (resp.status_code == 401 || resp.status_code == 404) {
        throw RecordNotFoundException();
    }
    check_response(resp, "Delivery poll");

    std::vector<PendingDelivery> result;
    try {
        auto j = nlohmann::json::parse(resp.body);
        if (j.is_object() && j.contains("deliveries") && j["deliveries"].is_array()) {
            for (const auto& item : j["deliveries"]) {
                if (item.contains("delivery_id") && item.contains("envelope")) {
                    result.push_back(PendingDelivery{
                        item["delivery_id"].get<std::string>(),
                        item["envelope"]
                    });
                }
            }
        }
    } catch (const std::exception& e) {
        throw ApiException(std::string("Failed to parse pending deliveries: ") + e.what());
    }

    return result;
}

void ApiClient::ack_delivery(
    const std::string& server_url,
    const std::string& record_id,
    const std::string& delivery_id
) {
    std::string url = server_url + "/api/v1/record/deliveries/" + delivery_id;
    std::vector<std::string> headers = {"authorization: Bearer " + record_id};

    HttpResponse resp = transport_->request("DELETE", url, headers, "");
    if (resp.status_code == 401 || resp.status_code == 404) {
        return; // Already deleted
    }
    check_response(resp, "Delivery ack");
}

TestCode ApiClient::send_test_code(
    const std::string& server_url,
    const std::string& record_id
) {
    std::string url = server_url + "/api/v1/record/test";
    std::vector<std::string> headers = {"authorization: Bearer " + record_id};

    HttpResponse resp = transport_->request("POST", url, headers, "");
    if (resp.status_code == 401 || resp.status_code == 404) {
        throw RecordNotFoundException();
    }
    if (resp.status_code == 409 && extract_error_code(resp.body) == "no_devices") {
        throw NoDevicesException();
    }
    check_response(resp, "Test code");

    try {
        auto j = nlohmann::json::parse(resp.body);
        if (!j.contains("otp") || !j.contains("devices") || !j["devices"].is_number_integer()) {
            throw ApiException("Test code returned an incomplete response");
        }
        return TestCode{
            j["otp"].get<std::string>(),
            j["devices"].get<int>()
        };
    } catch (const std::exception& e) {
        throw ApiException(std::string("Failed to parse test code response: ") + e.what());
    }
}

ServerHealth ApiClient::check_health(const std::string& server_url) {
    std::string url = server_url + "/health";
    try {
        HttpResponse resp = transport_->request("GET", url, {}, "", 10);
        std::string status;
        try {
            auto j = nlohmann::json::parse(resp.body);
            if (j.is_object() && j.contains("status") && j["status"].is_string()) {
                status = j["status"].get<std::string>();
            }
        } catch (...) {}

        if (resp.status_code == 200 && status == "ok") {
            return ServerHealth{ServerHealthState::Reachable, ""};
        }

        std::string reason;
        if (resp.status_code == 503 && !status.empty()) {
            reason = "its database is unavailable";
        } else if (resp.status_code == 200) {
            reason = "the answer isn't from a pux server";
        } else {
            reason = "HTTP " + std::to_string(resp.status_code);
        }
        return ServerHealth{ServerHealthState::ServerError, reason};
    } catch (const std::exception& e) {
        return ServerHealth{ServerHealthState::Unreachable, e.what()};
    }
}

std::string ApiClient::delivery_websocket_url(const std::string& server_url) {
    std::string url = server_url;
    if (url.rfind("https://", 0) == 0) {
        url.replace(0, 8, "wss://");
    } else if (url.rfind("http://", 0) == 0) {
        url.replace(0, 7, "ws://");
    }
    while (!url.empty() && url.back() == '/') {
        url.pop_back();
    }
    return url + "/ws/delivery";
}

} // namespace api
} // namespace pux
