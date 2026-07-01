defmodule Pux.Workers.PushWorkerTest do
  use Pux.DataCase, async: false
  use Oban.Testing, repo: Pux.Repo

  alias Pux.{Fixtures, Push, Records}
  alias Pux.Workers.PushWorker

  import ExUnit.CaptureLog

  test "deliver_to_record enqueues push jobs for devices" do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    record = Records.get_record(enrollment.record_id)

    {:ok, device} =
      Records.register_device(enrollment.record_id, %{
        push_token: "fcm-token-xyz",
        platform: :fcm
      })

    plaintext = Jason.encode!(%{otp: "123456", sender: "Test"})

    assert :ok = Push.deliver_to_record(record, plaintext)

    assert_enqueued(worker: PushWorker, args: %{"device_id" => device.id})

    log =
      capture_log(fn ->
        assert :ok = perform_job(PushWorker, %{"device_id" => device.id, "envelope" => %{"ciphertext" => "abc"}})
      end)

    assert log =~ "FCM disabled" or log == ""
  end

  test "touch_device updates last_seen_at after successful push job" do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())

    {:ok, device} =
      Records.register_device(enrollment.record_id, %{
        push_token: "fcm-token-touch",
        platform: :fcm
      })

    stale_time = DateTime.utc_now(:microsecond) |> DateTime.add(-40, :day)

    device
    |> Ecto.Changeset.change(last_seen_at: stale_time)
    |> Pux.Repo.update!()

    {:ok, ciphertext} = Pux.Crypto.seal("{}", Records.get_record(enrollment.record_id).public_key)
    envelope = %{"ciphertext" => Pux.Crypto.encode_ciphertext(ciphertext)}

    capture_log(fn ->
      assert :ok = perform_job(PushWorker, %{"device_id" => device.id, "envelope" => envelope})
    end)

    refreshed = Records.get_device(device.id)
    assert DateTime.compare(refreshed.last_seen_at, stale_time) == :gt
  end

  test "deliver_to_record creates pending delivery for desktop devices" do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    record = Records.get_record(enrollment.record_id)

    {:ok, _} =
      Records.register_device(enrollment.record_id, %{
        push_token: "desktop-client-1",
        platform: :desktop
      })

    plaintext = Jason.encode!(%{otp: "654321", sender: "DesktopTest"})

    assert :ok = Push.deliver_to_record(record, plaintext)

    pending = Pux.Deliveries.list_pending(enrollment.record_id)
    assert length(pending) == 1
    assert pending |> hd() |> Map.fetch!(:envelope) |> Map.has_key?("ciphertext")
  end
end
