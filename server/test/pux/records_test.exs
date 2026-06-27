defmodule Pux.RecordsTest do
  use Pux.DataCase, async: true

  alias Pux.Records

  test "creates record with enrollment payload" do
    assert {:ok, enrollment} = Records.create_record()
    assert enrollment.record_id
    assert String.contains?(enrollment.inbox_address, "@")
    assert enrollment.qr_payload.v == 1
    assert Records.get_record(enrollment.record_id)
  end

  test "registers device for record" do
    {:ok, enrollment} = Records.create_record()

    assert {:ok, device} =
             Records.register_device(enrollment.record_id, %{
               push_token: "fcm-token-123",
               platform: :fcm
             })

    assert device.push_token == "fcm-token-123"
    assert length(Records.list_devices(enrollment.record_id)) == 1
  end
end
