defmodule Pux.Workers.PruneWorkerTest do
  use Pux.DataCase, async: false
  use Oban.Testing, repo: Pux.Repo

  alias Pux.{Deliveries, FCMStub, Fixtures, Push, Records}
  alias Pux.Workers.{PruneWorker, PushWorker, TokenCheckWorker}

  import ExUnit.CaptureLog

  defp relay do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    enrollment.record_id
  end

  defp add_device(record_id, platform) do
    {:ok, device} =
      Records.register_device(record_id, %{
        push_token: "#{platform}-token-#{System.unique_integer([:positive])}",
        platform: platform
      })

    device
  end

  defp age_device(device, days) do
    device
    |> Ecto.Changeset.change(last_seen_at: days_ago(days))
    |> Repo.update!()
  end

  defp age_record(record_id, days) do
    record_id
    |> Records.get_record()
    |> Ecto.Changeset.change(last_active_at: days_ago(days))
    |> Repo.update!()
  end

  defp days_ago(days), do: DateTime.utc_now(:microsecond) |> DateTime.add(-days, :day)

  defp prune do
    capture_log(fn -> assert :ok = perform_job(PruneWorker, %{}) end)
  end

  describe "FCM devices" do
    test "a quiet phone keeps its relay and still gets its code after the old limits" do
      FCMStub.start()
      record_id = relay()
      device = record_id |> add_device(:fcm) |> age_device(400)
      age_record(record_id, 400)

      prune()

      assert Records.get_device(device.id)
      record = Records.get_record(record_id)
      assert record

      # The whole mail path: the session's delivery step, then the push job.
      assert :ok = Records.touch_record(record)
      assert :ok = Push.deliver_to_record(record, ~s({"otp":"123456"}))
      [job] = all_enqueued(worker: PushWorker, args: %{"device_id" => device.id})

      capture_log(fn -> assert :ok = perform_job(PushWorker, job.args) end)

      assert_received {:fcm_request, request}
      assert request["message"]["token"] == device.push_token
      assert request["message"]["data"]["ciphertext"] == job.args["envelope"]["ciphertext"]
      refute Map.has_key?(request, "validate_only")
    end

    test "an unregistered token is removed on the next send" do
      device = relay() |> add_device(:fcm)
      FCMStub.start(%{device.push_token => FCMStub.unregistered()})

      capture_log(fn ->
        assert :ok =
                 perform_job(PushWorker, %{
                   "device_id" => device.id,
                   "envelope" => %{"ciphertext" => "c"}
                 })
      end)

      refute Records.get_device(device.id)
    end

    test "a failed send doesn't remove the token" do
      device = relay() |> add_device(:fcm)
      FCMStub.start(%{device.push_token => {503, "{}"}})

      capture_log(fn ->
        assert {:error, _} =
                 perform_job(PushWorker, %{
                   "device_id" => device.id,
                   "envelope" => %{"ciphertext" => "c"}
                 })
      end)

      assert Records.get_device(device.id)
    end

    test "only quiet FCM tokens are queued for a check" do
      FCMStub.start()
      record_id = relay()
      quiet = record_id |> add_device(:fcm) |> age_device(31)
      recent = record_id |> add_device(:fcm) |> age_device(29)
      desktop = record_id |> add_device(:desktop) |> age_device(31)

      prune()

      assert_enqueued(worker: TokenCheckWorker, args: %{"device_id" => quiet.id})
      refute_enqueued(worker: TokenCheckWorker, args: %{"device_id" => recent.id})
      refute_enqueued(worker: TokenCheckWorker, args: %{"device_id" => desktop.id})
    end

    test "with no quiet tokens there is nothing to queue" do
      FCMStub.start()
      relay() |> add_device(:fcm)

      prune()

      refute_enqueued(worker: TokenCheckWorker)
    end

    test "no checks are queued without FCM, which couldn't answer" do
      relay() |> add_device(:fcm) |> age_device(400)

      prune()

      refute_enqueued(worker: TokenCheckWorker)
    end

    test "a dead token on a quiet relay is found by the check, and the relay then ages out" do
      record_id = relay()
      device = record_id |> add_device(:fcm) |> age_device(400)
      age_record(record_id, 400)
      FCMStub.start(%{device.push_token => FCMStub.unregistered()})

      prune()
      [job] = all_enqueued(worker: TokenCheckWorker)
      capture_log(fn -> assert :ok = perform_job(TokenCheckWorker, job.args) end)

      assert_received {:fcm_request, %{"validate_only" => true}}
      refute Records.get_device(device.id)

      # The check restarted the clock, so an app that merely lost its token can re-register.
      prune()
      assert Records.get_record(record_id)

      age_record(record_id, 31)
      prune()
      refute Records.get_record(record_id)
    end

    test "a passing check keeps the device and isn't repeated tomorrow" do
      FCMStub.start()
      device = relay() |> add_device(:fcm) |> age_device(31)

      capture_log(fn ->
        assert :ok = perform_job(TokenCheckWorker, %{"device_id" => device.id})
      end)

      refreshed = Records.get_device(device.id)
      assert DateTime.compare(refreshed.last_seen_at, days_ago(1)) == :gt
      assert Records.list_quiet_fcm_device_ids(30) == []
    end

    test "a failed check doesn't remove the device" do
      device = relay() |> add_device(:fcm) |> age_device(31)
      FCMStub.start(%{device.push_token => {503, "{}"}})

      capture_log(fn ->
        assert {:error, _} = perform_job(TokenCheckWorker, %{"device_id" => device.id})
      end)

      assert Records.get_device(device.id)
    end

    test "at the device cap, dead tokens clear on the next send so a new phone can join" do
      record_id = relay()
      devices = for _ <- 1..10, do: add_device(record_id, :fcm)

      responses = Map.new(devices, &{&1.push_token, FCMStub.unregistered()})
      FCMStub.start(responses)

      new_phone = %{push_token: "fcm-token-new-phone", platform: :fcm}
      assert {:error, :too_many_devices} = Records.register_device(record_id, new_phone)

      assert :ok = Push.deliver_to_record(Records.get_record(record_id), ~s({"otp":"1"}))

      capture_log(fn -> Oban.drain_queue(queue: :push) end)

      assert {:ok, _} = Records.register_device(record_id, new_phone)
    end
  end

  describe "desktop devices" do
    test "age out, which frees their slot under the device cap" do
      record_id = relay()
      stale = record_id |> add_device(:desktop) |> age_device(91)
      fresh = record_id |> add_device(:desktop) |> age_device(89)

      prune()

      refute Records.get_device(stale.id)
      assert Records.get_device(fresh.id)
    end

    test "re-registering restarts the age limit" do
      record_id = relay()
      device = record_id |> add_device(:desktop) |> age_device(89)

      {:ok, _} =
        Records.register_device(record_id, %{push_token: device.push_token, platform: :desktop})

      refreshed = Records.get_device(device.id)
      assert DateTime.compare(refreshed.last_seen_at, days_ago(1)) == :gt

      prune()
      assert Records.get_device(device.id)
    end

    test "a relay left with only stale desktops gets a grace period, then goes" do
      record_id = relay()
      device = record_id |> add_device(:desktop) |> age_device(91)
      age_record(record_id, 91)

      prune()

      refute Records.get_device(device.id)
      assert Records.get_record(record_id), "the app can still come back and re-register"

      age_record(record_id, 31)
      prune()

      refute Records.get_record(record_id)
    end

    test "a desktop coming back during the grace period keeps the relay" do
      record_id = relay()
      device = record_id |> add_device(:desktop) |> age_device(91)
      age_record(record_id, 91)

      prune()

      assert {:ok, _} =
               Records.register_device(record_id, %{
                 push_token: device.push_token,
                 platform: :desktop
               })

      age_record(record_id, 31)
      prune()

      assert Records.get_record(record_id)
    end
  end

  describe "records" do
    test "one with no devices is pruned after the TTL, not before" do
      abandoned = relay()
      age_record(abandoned, 31)
      recent = relay()
      age_record(recent, 29)

      prune()

      refute Records.get_record(abandoned)
      assert Records.get_record(recent)
    end

    test "one that still has a device doesn't age out, even a desktop within its limit" do
      with_phone = relay()
      add_device(with_phone, :fcm)
      age_record(with_phone, 400)

      with_desktop = relay()
      add_device(with_desktop, :desktop)
      age_record(with_desktop, 400)

      prune()

      assert Records.get_record(with_phone)
      assert Records.get_record(with_desktop)
    end

    test "removing the last device by hand starts no grace period" do
      record_id = relay()
      device = add_device(record_id, :fcm)
      age_record(record_id, 31)

      assert :ok = Records.delete_record_device(record_id, device.id)
      prune()

      refute Records.get_record(record_id)
    end
  end

  describe "pending deliveries" do
    setup do
      record_id = relay()
      add_device(record_id, :desktop)

      {:ok, pending} = Deliveries.create_pending(record_id, %{"ciphertext" => "old"})

      pending
      |> Ecto.Changeset.change(
        inserted_at: DateTime.add(DateTime.utc_now(:microsecond), -20, :minute)
      )
      |> Repo.update!()

      {:ok, record_id: record_id}
    end

    test "still expire after minutes, in the frequent job", %{record_id: record_id} do
      assert :ok = perform_job(PruneWorker, %{"scope" => "deliveries"})

      assert Deliveries.list_pending(record_id) == []
      assert Records.get_record(record_id)
    end

    test "still expire in the nightly job, which keeps the relay", %{record_id: record_id} do
      prune()

      assert Deliveries.list_pending(record_id) == []
      assert Records.get_record(record_id)
    end
  end

  test "a token reported dead is removed from every relay that has it" do
    first = relay()
    second = relay()
    token = "fcm-token-on-two-relays"

    {:ok, _} = Records.register_device(first, %{push_token: token, platform: :fcm})
    {:ok, _} = Records.register_device(second, %{push_token: token, platform: :fcm})
    age_record(first, 400)

    assert Records.delete_devices_by_token(token) == 2

    assert Records.list_devices(first) == []
    assert Records.list_devices(second) == []
    assert DateTime.compare(Records.get_record(first).last_active_at, days_ago(1)) == :gt
  end
end
