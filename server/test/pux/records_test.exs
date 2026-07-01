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
end
