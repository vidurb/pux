defmodule Pux.RecordsTest do
  use Pux.DataCase, async: true

  alias Pux.Fixtures
  alias Pux.Records

  test "creates record with client-supplied public key" do
    public_key = Fixtures.public_key()

    assert {:ok, enrollment} = Records.create_record(public_key)
    assert enrollment.record_id
    assert String.contains?(enrollment.inbox_address, "@")
    assert enrollment.public_key
    assert Records.get_record(enrollment.record_id)
  end

  test "registers device for record" do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())

    assert {:ok, device} =
             Records.register_device(enrollment.record_id, %{
               push_token: "fcm-token-123",
               platform: :fcm
             })

    assert device.push_token == "fcm-token-123"
    assert length(Records.list_devices(enrollment.record_id)) == 1
  end

  test "registers desktop device for record" do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())

    assert {:ok, device} =
             Records.register_device(enrollment.record_id, %{
               push_token: "desktop-client-1",
               platform: :desktop
             })

    assert device.platform == :desktop
  end

  test "inbox tokens are 24 characters from the lowercase alphanumeric alphabet" do
    for _ <- 1..20 do
      {:ok, enrollment} = Records.create_record(Fixtures.public_key())
      assert enrollment.inbox_token =~ ~r/\A[a-z0-9]{24}\z/
    end
  end

  test "caps devices per record but allows re-registering an existing token" do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())

    for i <- 1..10 do
      assert {:ok, _} =
               Records.register_device(enrollment.record_id, %{
                 push_token: "fcm-token-#{i}",
                 platform: :fcm
               })
    end

    assert {:error, :too_many_devices} =
             Records.register_device(enrollment.record_id, %{
               push_token: "fcm-token-11",
               platform: :fcm
             })

    assert {:ok, _} =
             Records.register_device(enrollment.record_id, %{
               push_token: "fcm-token-3",
               platform: :fcm
             })

    assert length(Records.list_devices(enrollment.record_id)) == 10
  end

  test "re-registering a token returns the device's own ID" do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    attrs = %{push_token: "fcm-token-again", platform: :fcm}

    {:ok, first} = Records.register_device(enrollment.record_id, attrs)
    {:ok, again} = Records.register_device(enrollment.record_id, attrs)

    assert again.id == first.id
    assert [%{id: id}] = Records.list_devices(enrollment.record_id)
    assert id == first.id
  end

  test "register_device returns not_found for an unknown record" do
    assert {:error, :not_found} =
             Records.register_device(Ecto.UUID.generate(), %{
               push_token: "fcm-token-123",
               platform: :fcm
             })
  end

  test "delete_record_device is scoped to the record" do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    {:ok, other} = Records.create_record(Fixtures.public_key())

    {:ok, device} =
      Records.register_device(enrollment.record_id, %{push_token: "fcm-token-1", platform: :fcm})

    assert {:error, :not_found} = Records.delete_record_device(other.record_id, device.id)
    assert {:error, :not_found} = Records.delete_record_device(enrollment.record_id, "nope")
    assert :ok = Records.delete_record_device(enrollment.record_id, device.id)
    assert {:error, :not_found} = Records.delete_record_device(enrollment.record_id, device.id)
    assert Records.list_devices(enrollment.record_id) == []
  end

  test "delete_record cascades and notifies delivery subscribers" do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())

    {:ok, _} =
      Records.register_device(enrollment.record_id, %{push_token: "desktop-1", platform: :desktop})

    {:ok, _} = Pux.Deliveries.create_pending(enrollment.record_id, %{"ciphertext" => "x"})

    Phoenix.PubSub.subscribe(Pux.PubSub, Pux.Push.delivery_topic(enrollment.record_id))

    assert :ok = Records.delete_record(enrollment.record_id)
    assert_receive :record_deleted

    refute Records.get_record(enrollment.record_id)
    assert Records.list_devices(enrollment.record_id) == []
    assert Pux.Deliveries.list_pending(enrollment.record_id) == []

    assert :ok = Records.delete_record(enrollment.record_id)
    refute_receive :record_deleted
  end
end
