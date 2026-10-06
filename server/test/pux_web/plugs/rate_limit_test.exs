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
end
