defmodule PuxWeb.Plugs.RecordRateLimitTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias PuxWeb.Plugs.RecordRateLimit

  defp call(record_id, opts) do
    conn(:get, "/api/v1/record/deliveries")
    |> assign(:record_id, record_id)
    |> RecordRateLimit.call(RecordRateLimit.init(opts))
  end

  test "limits requests per record" do
    record_id = Ecto.UUID.generate()
    opts = [key: "record_api_test", limit: 2, scale_ms: 60_000]

    refute call(record_id, opts).halted
    refute call(record_id, opts).halted

    conn = call(record_id, opts)
    assert conn.halted
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body) == %{"error" => "rate_limit_exceeded"}

    refute call(Ecto.UUID.generate(), opts).halted
  end

  test "takes its limit from another config entry when given one" do
    record_id = Ecto.UUID.generate()
    limit = Application.fetch_env!(:pux, :test_code_rate_limit)[:limit]
    opts = [config: :test_code_rate_limit, key: "record_test_plug"]

    for _ <- 1..limit, do: refute(call(record_id, opts).halted)
    assert call(record_id, opts).status == 429

    # A separate bucket from the general limit.
    refute call(record_id, key: "record_api_plug").halted
  end
end
