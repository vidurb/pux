defmodule Pux.Workers.FidPushTest do
  @moduledoc """
  Phones register Firebase Installation IDs, older builds registration tokens. Both are
  stored in `push_token` and must reach FCM in the right field, be removed when FCM reports
  them dead, and leave one device row per phone when one replaces the other.
  """
  use Pux.DataCase, async: false
  use Oban.Testing, repo: Pux.Repo

  alias Pux.{Deliveries, FCMStub, Fixtures, Push, Records}
  alias Pux.Workers.{PushWorker, TokenCheckWorker}

  import ExUnit.CaptureLog

  @fid "cK3xyBMtTnu-Wd_9Q2Zk1a"
  @new_fid "fQ8_bLmZr2w-Xy7aAbCdEf"
  @token "cK3xyBMtTnu-Wd_9Q2Zk1a:APA91bH" <> String.duplicate("x", 140)

  defp relay do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    enrollment.record_id
  end

  defp register(record_id, push_token, opts \\ []) do
    attrs = %{push_token: push_token, platform: Keyword.get(opts, :platform, :fcm)}
    attrs = if opts[:replaces], do: Map.put(attrs, :replaces, opts[:replaces]), else: attrs
    {:ok, device} = Records.register_device(record_id, attrs)
    device
  end

  defp push(device) do
    capture_log(fn ->
      perform_job(PushWorker, %{"device_id" => device.id, "envelope" => %{"ciphertext" => "c"}})
    end)
  end

  describe "sending" do
    test "an FID goes out as message.fid and a legacy token as message.token" do
      FCMStub.start()
      record_id = relay()
      phone = register(record_id, @fid)
      old_phone = register(record_id, @token)

      push(phone)
      assert_received {:fcm_request, %{"message" => message}}
      assert message["fid"] == @fid
      refute Map.has_key?(message, "token")

      push(old_phone)
      assert_received {:fcm_request, %{"message" => message}}
      assert message["token"] == @token
      refute Map.has_key?(message, "fid")
    end

    test "an FID FCM reports unregistered is removed on the next send" do
      FCMStub.start(%{@fid => FCMStub.unregistered()})
      record_id = relay()
      phone = register(record_id, @fid)
      other = register(record_id, @new_fid)

      push(phone)

      refute Records.get_device(phone.id)
      assert Records.get_device(other.id)
    end

    test "an FID FCM calls invalid is removed too" do
      body =
        Jason.encode!(%{
          "error" => %{
            "status" => "INVALID_ARGUMENT",
            "details" => [
              %{
                "@type" => "type.googleapis.com/google.rpc.BadRequest",
                "fieldViolations" => [%{"field" => "message.fid"}]
              }
            ]
          }
        })

      FCMStub.start(%{@fid => {400, body}})
      phone = relay() |> register(@fid)

      push(phone)

      refute Records.get_device(phone.id)
    end

    test "the quiet-device check sends the FID as fid and removes a dead one" do
      FCMStub.start(%{@fid => FCMStub.unregistered()})
      phone = relay() |> register(@fid)

      capture_log(fn ->
        assert :ok = perform_job(TokenCheckWorker, %{"device_id" => phone.id})
      end)

      assert_received {:fcm_request, %{"validate_only" => true, "message" => %{"fid" => @fid}}}
      refute Records.get_device(phone.id)
    end
  end

  describe "a phone whose push token changes" do
    test "keeps one device row, and gets each code once at the new token" do
      FCMStub.start()
      record_id = relay()
      before = register(record_id, @token)

      after_switch = register(record_id, @fid, replaces: before.id)

      assert after_switch.id == before.id
      assert [%{push_token: @fid}] = Records.list_devices(record_id)

      Push.deliver_to_record(Records.get_record(record_id), ~s({"otp":"1"}))
      assert [job] = all_enqueued(worker: PushWorker)
      capture_log(fn -> assert :ok = perform_job(PushWorker, job.args) end)

      assert_received {:fcm_request, %{"message" => %{"fid" => @fid}}}
      refute_received {:fcm_request, _}
    end

    test "can refresh to a new FID the same way" do
      record_id = relay()
      device = register(record_id, @fid)

      assert register(record_id, @new_fid, replaces: device.id).id == device.id
      assert [%{push_token: @new_fid}] = Records.list_devices(record_id)
    end

    test "forgets the old token's passed check, which says nothing about the new one" do
      record_id = relay()
      device = register(record_id, @token)
      Records.mark_token_checked(device)

      replaced = register(record_id, @fid, replaces: device.id)

      assert replaced.token_checked_at == nil
    end

    test "is allowed at the device cap, since no device is added" do
      record_id = relay()
      device = register(record_id, @token)
      for i <- 2..10, do: register(record_id, "fcm-token-#{i}")

      assert {:error, :too_many_devices} =
               Records.register_device(record_id, %{push_token: @fid, platform: :fcm})

      assert {:ok, %{id: id}} =
               Records.register_device(record_id, %{
                 push_token: @fid,
                 platform: :fcm,
                 replaces: device.id
               })

      assert id == device.id
      assert length(Records.list_devices(record_id)) == 10
    end

    test "merges into the new token's row if that was registered separately" do
      record_id = relay()
      old = register(record_id, @token)
      new = register(record_id, @fid)

      assert register(record_id, @fid, replaces: old.id).id == new.id
      assert [%{id: id, push_token: @fid}] = Records.list_devices(record_id)
      assert id == new.id
    end

    test "registers normally if the old device is gone, as when FCM reported it dead" do
      record_id = relay()
      old = register(record_id, @token)
      Records.delete_devices_by_token(@token)

      new = register(record_id, @fid, replaces: old.id)

      assert new.id != old.id
      assert [%{push_token: @fid}] = Records.list_devices(record_id)
    end

    test "can't replace another relay's device" do
      mine = relay()
      theirs = relay()
      their_device = register(theirs, @token)

      register(mine, @fid, replaces: their_device.id)

      assert [%{push_token: @token}] = Records.list_devices(theirs)
      assert [%{push_token: @fid}] = Records.list_devices(mine)
    end

    test "ignores a malformed device ID" do
      record_id = relay()
      register(record_id, @token)

      register(record_id, @fid, replaces: "not-a-uuid")

      assert length(Records.list_devices(record_id)) == 2
    end
  end

  describe "desktop devices" do
    test "are never replaced by a phone" do
      record_id = relay()
      desktop = register(record_id, "0123456789abcdef0123456789abcdef", platform: :desktop)

      register(record_id, @fid, replaces: desktop.id)

      assert %{platform: :desktop, push_token: "0123456789abcdef0123456789abcdef"} =
               Records.get_device(desktop.id)

      assert length(Records.list_devices(record_id)) == 2
    end

    test "ignore a device ID sent with their own registration" do
      record_id = relay()
      desktop = register(record_id, "0123456789abcdef0123456789abcdef", platform: :desktop)

      register(record_id, "fedcba9876543210fedcba9876543210",
        platform: :desktop,
        replaces: desktop.id
      )

      assert length(Records.list_devices(record_id)) == 2

      Push.deliver_to_record(Records.get_record(record_id), ~s({"otp":"1"}))
      refute_enqueued(worker: PushWorker)
      assert [_] = Deliveries.list_pending(record_id)
    end

    test "with an ID shaped like an FID still get no push" do
      record_id = relay()
      register(record_id, @fid, platform: :desktop)

      Push.deliver_to_record(Records.get_record(record_id), ~s({"otp":"1"}))

      refute_enqueued(worker: PushWorker)
    end
  end
end
