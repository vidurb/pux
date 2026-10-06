defmodule PuxWeb.DeliverySocketTest do
  @moduledoc "Opens real WebSocket connections against the test endpoint (port 4002)."
  use PuxWeb.ConnCase, async: false

  import Bitwise

  alias Pux.{Deliveries, Fixtures, Push, Records}

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

  test "accepts the legacy query param", %{enrollment: e} do
    assert {:ok, _socket} = ws_connect("/ws/delivery?token=#{e.record_id}", [])
  end

  test "pushes envelopes delivered to the record", %{enrollment: e} do
    {:ok, _} =
      Records.register_device(e.record_id, %{push_token: "desktop-client-1", platform: :desktop})

    assert {:ok, socket} = ws_connect("/ws/delivery", [{"x-pux-token", e.record_id}])

    record = Records.get_record(e.record_id)
    assert :ok = Push.deliver_to_record(record, Jason.encode!(%{otp: "111222"}))

    assert %{"type" => "envelope", "delivery_id" => id, "envelope" => %{"ciphertext" => _}} =
             recv_json(socket)

    assert [%{id: ^id}] = Deliveries.list_pending(e.record_id)
  end

  defp ws_connect(path, headers) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", 4002, [:binary, active: false])
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
