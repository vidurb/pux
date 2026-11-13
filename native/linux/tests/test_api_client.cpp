#include "test_harness.hpp"
#include "../src/api/api_client.hpp"

namespace {

class MockHttpTransport : public pux::api::HttpTransport {
public:
    struct RecordedRequest {
        std::string method;
        std::string url;
        std::vector<std::string> headers;
        std::string body;
    };

    std::vector<RecordedRequest> requests;
    pux::api::HttpResponse next_response{200, "{}"};

    pux::api::HttpResponse request(
        const std::string& method,
        const std::string& url,
        const std::vector<std::string>& headers,
        const std::string& body,
        long /*timeout_seconds*/
    ) override {
        requests.push_back({method, url, headers, body});
        return next_response;
    }
};

} // namespace

TEST(api_client_delivery_websocket_url) {
    ASSERT_EQ(
        pux::api::ApiClient::delivery_websocket_url("https://pux.vidur.xyz"),
        "wss://pux.vidur.xyz/ws/delivery"
    );
    ASSERT_EQ(
        pux::api::ApiClient::delivery_websocket_url("https://pux.vidur.xyz/"),
        "wss://pux.vidur.xyz/ws/delivery"
    );
    ASSERT_EQ(
        pux::api::ApiClient::delivery_websocket_url("http://localhost:4000"),
        "ws://localhost:4000/ws/delivery"
    );
}

TEST(api_client_create_record) {
    auto mock = std::make_shared<MockHttpTransport>();
    mock->next_response = {200, "{\"record_id\":\"rec-123\",\"inbox_address\":\"inbox@pux.xyz\"}"};

    pux::api::ApiClient client(mock);
    auto res = client.create_record("https://pux.vidur.xyz", "test-pubkey");

    ASSERT_EQ(res.record_id, "rec-123");
    ASSERT_EQ(res.inbox_address, "inbox@pux.xyz");
    ASSERT_EQ(mock->requests.size(), 1);
    ASSERT_EQ(mock->requests[0].method, "POST");
    ASSERT_EQ(mock->requests[0].url, "https://pux.vidur.xyz/api/v1/records");
}

TEST(api_client_register_device_bearer_auth) {
    auto mock = std::make_shared<MockHttpTransport>();
    mock->next_response = {200, "{\"device_id\":\"dev-999\"}"};

    pux::api::ApiClient client(mock);
    auto dev_id = client.register_device(
        "https://pux.vidur.xyz",
        "rec-123",
        "token-abc",
        "desktop"
    );

    ASSERT_EQ(dev_id, "dev-999");
    ASSERT_EQ(mock->requests.size(), 1);
    ASSERT_EQ(mock->requests[0].url, "https://pux.vidur.xyz/api/v1/record/devices");

    bool has_auth = false;
    for (const auto& h : mock->requests[0].headers) {
        if (h == "authorization: Bearer rec-123") {
            has_auth = true;
            break;
        }
    }
    ASSERT_TRUE(has_auth);
}

TEST(api_client_rejects_missing_registration_id) {
    auto mock = std::make_shared<MockHttpTransport>();
    pux::api::ApiClient client(mock);
    for (const auto& body : {"{}", "{\"device_id\":\"\"}", "not json"}) {
        mock->next_response = {200, body};
        ASSERT_THROWS(client.register_device("https://pux.vidur.xyz", "rec-123", "token"), pux::api::ApiException);
    }
}

TEST(api_client_maps_exceptions) {
    auto mock = std::make_shared<MockHttpTransport>();
    pux::api::ApiClient client(mock);

    // 401 / 404 -> RecordNotFoundException
    mock->next_response = {401, "{\"error\":\"unauthorized\"}"};
    ASSERT_THROWS(
        client.list_pending_deliveries("https://pux.vidur.xyz", "rec-123"),
        pux::api::RecordNotFoundException
    );

    mock->next_response = {404, "{\"error\":\"not_found\"}"};
    ASSERT_THROWS(
        client.list_pending_deliveries("https://pux.vidur.xyz", "rec-123"),
        pux::api::RecordNotFoundException
    );

    // 422 too_many_devices -> TooManyDevicesException
    mock->next_response = {422, "{\"error\":\"too_many_devices\"}"};
    ASSERT_THROWS(
        client.register_device("https://pux.vidur.xyz", "rec-123", "token"),
        pux::api::TooManyDevicesException
    );

    // 429 -> RateLimitedException
    mock->next_response = {429, "{\"error\":\"rate_limit_exceeded\"}"};
    ASSERT_THROWS(
        client.create_record("https://pux.vidur.xyz", "pubkey"),
        pux::api::RateLimitedException
    );

    // 409 no_devices -> NoDevicesException
    mock->next_response = {409, "{\"error\":\"no_devices\"}"};
    ASSERT_THROWS(
        client.send_test_code("https://pux.vidur.xyz", "rec-123"),
        pux::api::NoDevicesException
    );
}

TEST(api_client_list_pending_deliveries) {
    auto mock = std::make_shared<MockHttpTransport>();
    mock->next_response = {
        200,
        "{\"deliveries\":[{\"delivery_id\":\"del-1\",\"envelope\":{\"ciphertext\":\"c1\"}}]}"
    };

    pux::api::ApiClient client(mock);
    auto list = client.list_pending_deliveries("https://pux.vidur.xyz", "rec-123");

    ASSERT_EQ(list.size(), 1);
    ASSERT_EQ(list[0].delivery_id, "del-1");
    ASSERT_EQ(list[0].envelope["ciphertext"].get<std::string>(), "c1");
}
