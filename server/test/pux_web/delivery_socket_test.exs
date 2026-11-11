defmodule PuxWeb.DeliverySocketTest do
  @moduledoc "Opens real WebSocket connections against the test endpoint (port 4002 unless PUX_TEST_HTTP_PORT is set)."
  use PuxWeb.ConnCase, async: false

  import Bitwise

  alias Pux.{Deliveries, Fixtures, Push, Records}
  alias PuxWeb.DeliverySocket

  setup do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    {:ok, enrollment: enrollment}
  end

  test "rejects a missing token" do
    assert {:status, 403} = ws_connect("/ws/delivery", [])
  end

  test "rejects an unknown record" do
    assert {:status, 403} = ws_connect("/ws/delivery", [{"x-pux-token", Ecto.UUID.generate()}])
  end

  test "accepts the token header and answers pings", %{enrollment: e} do
    assert {:ok, socket} = ws_connect("/ws/delivery", [{"x-pux-token", e.record_id}])
    send_text(socket, ~s({"type":"ping"}))
    assert %{"type" => "pong"} = recv_json(socket)
  end

  test "rejects the removed query param fallback", %{enrollment: e} do
    assert {:status, 403} = ws_connect("/ws/delivery?token=#{e.record_id}", [])
  end

  test "closes open sockets when the record is deleted", %{enrollment: e} do
    assert {:ok, socket} = ws_connect("/ws/delivery", [{"x-pux-token", e.record_id}])
    send_text(socket, ~s({"type":"ping"}))
    assert %{"type" => "pong"} = recv_json(socket)

    assert :ok = Records.delete_record(e.record_id)

    assert recv_closed(socket)
  end

  test "pushes envelopes delivered to the record", %{enrollment: e} do
    {:ok, _} =
      Records.register_device(e.record_id, %{push_token: "desktop-client-1", platform: :desktop})

    assert {:ok, socket} = ws_connect("/ws/delivery", [{"x-pux-token", e.record_id}])

    # The 101 can arrive before the socket process subscribes; a pong means init/1 ran.
    send_text(socket, ~s({"type":"ping"}))
    assert %{"type" => "pong"} = recv_json(socket)

    record = Records.get_record(e.record_id)
    assert :ok = Push.deliver_to_record(record, Jason.encode!(%{otp: "111222"}))

    assert %{"type" => "envelope", "delivery_id" => id, "envelope" => %{"ciphertext" => _}} =
             recv_json(socket)

    assert [%{id: ^id}] = Deliveries.list_pending(e.record_id)
  end

  test "an uppercase token receives envelopes", %{enrollment: e} do
    {:ok, _} =
      Records.register_device(e.record_id, %{push_token: "desktop-client-2", platform: :desktop})

    assert {:ok, socket} =
             ws_connect("/ws/delivery", [{"x-pux-token", String.upcase(e.record_id)}])

    send_text(socket, ~s({"type":"ping"}))
    assert %{"type" => "pong"} = recv_json(socket)

    assert :ok =
             Push.deliver_to_record(Records.get_record(e.record_id), Jason.encode!(%{otp: "1"}))

    assert %{"type" => "envelope"} = recv_json(socket)

    assert :ok = Records.delete_record(e.record_id)
    assert recv_closed(socket)
  end

  test "connect/1 returns the stored record ID", %{enrollment: e} do
    assert {:ok, %{record_id: id}} =
             DeliverySocket.connect(transport({198, 51, 100, 9}, String.upcase(e.record_id)))

    assert id == e.record_id
  end

  describe "failed authentication limit" do
    setup do
      limit(2)

      test_pid = self()
      handler = "delivery-socket-queries-#{System.unique_integer()}"
      :telemetry.attach(handler, [:pux, :repo, :query], &__MODULE__.notify_query/4, test_pid)
      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "over the limit answers 429 for any well-formed token, without a query", %{enrollment: e} do
      ip = {"x-forwarded-for", "203.0.113.20"}

      for _ <- 1..2 do
        assert {:status, 403} = ws_connect("/ws/delivery", [token_header(), ip])
      end

      flush_queries()

      for token <- [Ecto.UUID.generate(), e.record_id] do
        assert {:status, 429} = ws_connect("/ws/delivery", [{"x-pux-token", token}, ip])

        assert {:ok, %{status: 429, body: ~s({"error":"rate_limit_exceeded"}), headers: headers}} =
                 :get
                 |> Finch.build(url("/ws/delivery"), [{"x-pux-token", token}, ip])
                 |> Finch.request(Pux.Finch)

        assert {"content-type", "application/json; charset=utf-8"} in headers
      end

      refute_received {:query, _}

      assert {:ok, socket} =
               ws_connect("/ws/delivery", [
                 {"x-pux-token", e.record_id},
                 {"x-forwarded-for", "203.0.113.21"}
               ])

      :gen_tcp.close(socket)
    end

    test "working clients and malformed tokens don't count", %{enrollment: e} do
      ip = {"x-forwarded-for", "203.0.113.22"}

      for _ <- 1..3 do
        assert {:ok, socket} = ws_connect("/ws/delivery", [{"x-pux-token", e.record_id}, ip])
        :gen_tcp.close(socket)
        assert {:status, 403} = ws_connect("/ws/delivery", [{"x-pux-token", "not-a-uuid"}, ip])
        assert {:status, 403} = ws_connect("/ws/delivery", [ip])
      end

      assert {:status, 403} = ws_connect("/ws/delivery", [token_header(), ip])
    end

    test "shares its count with the REST API", %{conn: conn, enrollment: e} do
      for _ <- 1..2 do
        status =
          conn
          |> put_req_header("x-forwarded-for", "203.0.113.23")
          |> put_req_header("authorization", "Bearer #{Ecto.UUID.generate()}")
          |> get("/api/v1/record/deliveries")
          |> Map.fetch!(:status)

        assert status == 401
      end

      assert {:status, 429} =
               ws_connect("/ws/delivery", [
                 {"x-pux-token", e.record_id},
                 {"x-forwarded-for", "203.0.113.23"}
               ])
    end

    test "ignores X-Forwarded-For from a public peer", %{enrollment: e} do
      peer = {198, 51, 100, 30}

      for xff <- ["1.1.1.1", "2.2.2.2"] do
        assert :error = DeliverySocket.connect(transport(peer, Ecto.UUID.generate(), [xff]))
      end

      assert {:error, :rate_limited} =
               DeliverySocket.connect(transport(peer, e.record_id, ["3.3.3.3"]))

      assert {:ok, _} =
               DeliverySocket.connect(transport({198, 51, 100, 31}, e.record_id, ["1.1.1.1"]))
    end

    test "uses the rightmost hop from a private peer, like client_ip/1", %{enrollment: e} do
      peer = {0, 0, 0, 0, 0, 0xFFFF, 0x0AF4, 0x0005}

      for xff <- [["1.1.1.1, 203.0.113.40"], ["2.2.2.2", "203.0.113.40"]] do
        assert :error = DeliverySocket.connect(transport(peer, Ecto.UUID.generate(), xff))
      end

      assert {:error, :rate_limited} =
               DeliverySocket.connect(transport(peer, e.record_id, ["203.0.113.40"]))

      assert {:ok, _} = DeliverySocket.connect(transport(peer, e.record_id, ["203.0.113.41"]))
    end

    test "counts an IPv6 /64 as one client", %{enrollment: e} do
      peer = {10, 0, 0, 1}

      for xff <- ["2001:db8:5:6::1", "2001:db8:5:6:ffff::2"] do
        assert :error = DeliverySocket.connect(transport(peer, Ecto.UUID.generate(), [xff]))
      end

      assert {:error, :rate_limited} =
               DeliverySocket.connect(transport(peer, e.record_id, ["2001:db8:5:6::3"]))

      assert {:ok, _} = DeliverySocket.connect(transport(peer, e.record_id, ["2001:db8:5:7::1"]))
    end
  end

  def notify_query(_event, _measurements, %{source: "records"}, test_pid) do
    send(test_pid, {:query, :records})
  end

  def notify_query(_event, _measurements, _metadata, _test_pid), do: :ok

  defp flush_queries do
    receive do
      {:query, _} -> flush_queries()
    after
      0 -> :ok
    end
  end

  defp limit(limit) do
    config = Application.fetch_env!(:pux, :auth_failure_rate_limit)
    on_exit(fn -> Application.put_env(:pux, :auth_failure_rate_limit, config) end)

    Application.put_env(:pux, :auth_failure_rate_limit,
      key: "test_socket:#{System.unique_integer()}",
      limit: limit,
      scale_ms: 60_000
    )
  end

  defp token_header, do: {"x-pux-token", Ecto.UUID.generate()}

  # What Phoenix hands connect/1, for peers a test can't connect from.
  defp transport(peer, token, forwarded_for \\ []) do
    forwarded = Enum.map(forwarded_for, &{"x-forwarded-for", &1})

    %{
      connect_info: %{
        peer_data: %{address: peer, port: 1234, ssl_cert: nil},
        x_headers: [{"x-pux-token", token} | forwarded]
      }
    }
  end

  defp url(path), do: "http://127.0.0.1:#{http_port()}#{path}"

  defp http_port, do: Application.fetch_env!(:pux, PuxWeb.Endpoint)[:http][:port]

  defp ws_connect(path, headers) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", http_port(), [:binary, active: false])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    extra = Enum.map_join(headers, fn {k, v} -> "#{k}: #{v}\r\n" end)

    request =
      "GET #{path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n#{extra}\r\n"

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 2000)
    [status_line | _] = String.split(response, "\r\n")

    case status_line do
      "HTTP/1.1 101" <> _ -> {:ok, socket}
      "HTTP/1.1 " <> <<code::binary-size(3), _::binary>> -> {:status, String.to_integer(code)}
    end
  end

  defp send_text(socket, text) do
    mask = :crypto.strong_rand_bytes(4)
    masked = mask_payload(text, mask)
    len = byte_size(text)
    :ok = :gen_tcp.send(socket, <<1::1, 0::3, 1::4, 1::1, len::7, mask::binary, masked::binary>>)
  end

  defp mask_payload(payload, <<m::binary-size(4)>>) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> bxor(byte, :binary.at(m, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  # A close frame (opcode 8) or the TCP connection dropping.
  defp recv_closed(socket) do
    case :gen_tcp.recv(socket, 2, 2000) do
      {:ok, <<_fin::4, 8::4, _len>>} -> true
      {:error, :closed} -> true
    end
  end

  defp recv_json(socket) do
    {:ok, <<_fin_op, len_byte>>} = :gen_tcp.recv(socket, 2, 2000)

    len =
      case len_byte &&& 0x7F do
        126 ->
          {:ok, <<l::16>>} = :gen_tcp.recv(socket, 2, 2000)
          l

        l ->
          l
      end

    {:ok, payload} = :gen_tcp.recv(socket, len, 2000)
    Jason.decode!(payload)
  end
end
