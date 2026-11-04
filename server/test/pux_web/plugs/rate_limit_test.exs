defmodule PuxWeb.Plugs.RateLimitTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias PuxWeb.Plugs.RateLimit

  defp conn_from(remote_ip, xff) do
    conn = %{conn(:post, "/api/v1/records") | remote_ip: remote_ip}
    if xff, do: put_req_header(conn, "x-forwarded-for", xff), else: conn
  end

  test "uses the rightmost hop from a trusted proxy, ignoring spoofed hops" do
    assert RateLimit.client_ip(conn_from({10, 244, 0, 5}, "1.1.1.1, 203.0.113.7")) ==
             "203.0.113.7"
  end

  test "ignores X-Forwarded-For from a public peer" do
    assert RateLimit.client_ip(conn_from({198, 51, 100, 2}, "1.1.1.1")) == "198.51.100.2"
  end

  test "handles IPv4-mapped IPv6 peers" do
    assert RateLimit.client_ip(conn_from({0, 0, 0, 0, 0, 0xFFFF, 0x0AF4, 0x0005}, "203.0.113.9")) ==
             "203.0.113.9"
  end

  test "falls back to the peer without the header" do
    assert RateLimit.client_ip(conn_from({10, 0, 0, 1}, nil)) == "10.0.0.1"
  end

  describe "client_ip/2" do
    test "gives the same answer as client_ip/1" do
      for {peer, xff} <- [
            {{10, 244, 0, 5}, "1.1.1.1, 203.0.113.7"},
            {{198, 51, 100, 2}, "1.1.1.1"},
            {{0, 0, 0, 0, 0, 0xFFFF, 0x0AF4, 0x0005}, "203.0.113.9"},
            {{0, 0, 0, 0, 0, 0xFFFF, 0xC633, 0x6402}, "203.0.113.9"},
            {{10, 0, 0, 1}, nil},
            {{10, 0, 0, 1}, " , "}
          ] do
        headers = if xff, do: [xff], else: []

        assert RateLimit.client_ip(peer, headers) == RateLimit.client_ip(conn_from(peer, xff))
      end
    end

    test "uses the last hop of the last header line" do
      assert RateLimit.client_ip({10, 0, 0, 1}, ["1.1.1.1, 2.2.2.2", "203.0.113.7"]) ==
               "203.0.113.7"
    end
  end

  describe "limit_reached?/2" do
    test "doesn't count against the limit" do
      opts = [key: "test_peek:#{System.unique_integer()}", limit: 1, scale_ms: 60_000]

      for _ <- 1..3, do: refute(RateLimit.limit_reached?("client", opts))

      assert RateLimit.allow?("client", opts) == :ok
      assert RateLimit.limit_reached?("client", opts)
      refute RateLimit.limit_reached?("other", opts)
    end

    test "clears in a new window" do
      opts = [key: "test_peek_window:#{System.unique_integer()}", limit: 1, scale_ms: 50]

      assert RateLimit.allow?("client", opts) == :ok
      assert RateLimit.limit_reached?("client", opts)
      Process.sleep(110)
      refute RateLimit.limit_reached?("client", opts)
    end
  end

  describe "allow?/2" do
    test "allows up to the limit, then rate limits" do
      key = "test_allow:#{System.unique_integer()}"
      opts = [key: key, limit: 2, scale_ms: 60_000]

      assert RateLimit.allow?("client", opts) == :ok
      assert RateLimit.allow?("client", opts) == :ok
      assert RateLimit.allow?("client", opts) == {:error, :rate_limited}
      assert RateLimit.allow?("other", opts) == :ok
    end

    test "a new window resets the count" do
      opts = [key: "test_window:#{System.unique_integer()}", limit: 1, scale_ms: 50]

      assert RateLimit.allow?("client", opts) == :ok
      assert RateLimit.allow?("client", opts) == {:error, :rate_limited}
      Process.sleep(110)
      assert RateLimit.allow?("client", opts) == :ok
    end
  end

  describe "call/2" do
    test "passes through under the limit and returns 429 JSON once exceeded" do
      opts =
        RateLimit.init(key: "test_plug:#{System.unique_integer()}", limit: 1, scale_ms: 60_000)

      conn = RateLimit.call(conn_from({198, 51, 100, 7}, nil), opts)
      refute conn.halted

      conn = RateLimit.call(conn_from({198, 51, 100, 7}, nil), opts)
      assert conn.halted
      assert conn.status == 429
      assert Jason.decode!(conn.resp_body) == %{"error" => "rate_limit_exceeded"}

      refute RateLimit.call(conn_from({198, 51, 100, 8}, nil), opts).halted
    end
  end
end
