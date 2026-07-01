defmodule PuxWeb.DeliverySocketTest do
  use PuxWeb.ConnCase, async: false

  alias Pux.{Deliveries, Fixtures, Push, Records}

  setup do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    {:ok, enrollment: enrollment}
  end

  test "connect rejects missing token" do
    assert :error = PuxWeb.DeliverySocket.connect(%Plug.Conn{query_params: %{}})
  end

  test "connect accepts valid record token", %{enrollment: enrollment} do
    conn = %Plug.Conn{query_params: %{"token" => enrollment.record_id}}
    assert {:ok, %{record_id: ^record_id}} = PuxWeb.DeliverySocket.connect(conn)
    assert record_id == enrollment.record_id
  end

  test "handle_info pushes envelope frame", %{enrollment: enrollment} do
    state = %{record_id: enrollment.record_id}
    delivery_id = Ecto.UUID.generate()
    envelope = %{"ciphertext" => "abc123"}

    assert {:push, {:text, payload}, ^state} =
             PuxWeb.DeliverySocket.handle_info({:envelope, delivery_id, envelope}, state)

    decoded = Jason.decode!(payload)
    assert decoded["type"] == "envelope"
    assert decoded["delivery_id"] == delivery_id
    assert decoded["envelope"] == envelope
  end

  test "deliver_to_record broadcasts to subscribed socket", %{enrollment: enrollment} do
    {:ok, _} =
      Records.register_device(enrollment.record_id, %{
        push_token: "desktop-client-1",
        platform: :desktop
      })

    record = Records.get_record(enrollment.record_id)
    topic = Push.delivery_topic(enrollment.record_id)
    Phoenix.PubSub.subscribe(Pux.PubSub, topic)

    plaintext = Jason.encode!(%{otp: "111222", sender: "SocketTest"})
    assert :ok = Push.deliver_to_record(record, plaintext)

    assert_receive {:envelope, delivery_id, envelope}
    assert is_binary(delivery_id)
    assert Map.has_key?(envelope, "ciphertext")
    assert Deliveries.list_pending(enrollment.record_id) != []
  end
end
