defmodule Pux.Workers.PushWorkerTest do
  use Pux.DataCase, async: false
  use Oban.Testing, repo: Pux.Repo

  alias Pux.{Push, Records}
  alias Pux.Workers.PushWorker

  import ExUnit.CaptureLog

  test "deliver_to_record enqueues push jobs for devices" do
    {:ok, enrollment} = Records.create_record()
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
    {:ok, enrollment} = Records.create_record()

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
end
