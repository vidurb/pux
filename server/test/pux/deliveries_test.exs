defmodule Pux.DeliveriesTest do
  use Pux.DataCase, async: true

  alias Pux.{Deliveries, Fixtures, Records}

  setup do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    {:ok, enrollment: enrollment}
  end

  test "create, list, and ack pending deliveries", %{enrollment: enrollment} do
    envelope = %{"ciphertext" => "abc123"}

    assert {:ok, pending} = Deliveries.create_pending(enrollment.record_id, envelope)
    assert pending.envelope == envelope

    [listed] = Deliveries.list_pending(enrollment.record_id)
    assert listed.id == pending.id

    assert :ok = Deliveries.ack_pending(enrollment.record_id, pending.id)
    assert Deliveries.list_pending(enrollment.record_id) == []
  end

  test "ack returns not_found for wrong record", %{enrollment: enrollment} do
    {:ok, pending} = Deliveries.create_pending(enrollment.record_id, %{"ciphertext" => "x"})
    other_id = Ecto.UUID.generate()

    assert {:error, :not_found} = Deliveries.ack_pending(other_id, pending.id)
  end

  test "has_desktop_devices? reflects registered desktop devices", %{enrollment: enrollment} do
    refute Deliveries.has_desktop_devices?(enrollment.record_id)

    {:ok, _} =
      Records.register_device(enrollment.record_id, %{
        push_token: "desktop-client-1",
        platform: :desktop
      })

    assert Deliveries.has_desktop_devices?(enrollment.record_id)
  end

  test "prune_stale removes old pending deliveries", %{enrollment: enrollment} do
    {:ok, pending} = Deliveries.create_pending(enrollment.record_id, %{"ciphertext" => "old"})

    stale_time = DateTime.utc_now(:microsecond) |> DateTime.add(-20, :minute)

    pending
    |> Ecto.Changeset.change(inserted_at: stale_time)
    |> Pux.Repo.update!()

    assert Deliveries.prune_stale(10) == 1
    assert Deliveries.list_pending(enrollment.record_id) == []
  end
end
