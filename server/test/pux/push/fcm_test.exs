defmodule Pux.Push.FCMTest do
  use ExUnit.Case, async: false

  alias Pux.Push.FCM

  import ExUnit.CaptureLog

  setup do
    previous = Application.get_env(:pux, :fcm)
    on_exit(fn -> Application.put_env(:pux, :fcm, previous) end)
  end

  test "runtime.exs keyword config enables FCM and Goth" do
    json = Jason.encode!(%{"project_id" => "pux-test", "type" => "service_account"})
    Application.put_env(:pux, :fcm, enabled: true, project_id: "pux-test", service_account_json: json)

    assert FCM.enabled?()
    assert {Goth, opts} = FCM.goth_child_spec()
    assert opts[:name] == Pux.Goth
  end

  test "disabled config starts no Goth" do
    Application.put_env(:pux, :fcm, enabled: false)
    refute FCM.enabled?()
    assert FCM.goth_child_spec() == nil
  end

  test "android messages are high priority with a short TTL" do
    assert %{message: %{android: %{priority: "HIGH", ttl: "300s"}, data: %{"ciphertext" => "c"}}} =
             FCM.message("tok", %{"ciphertext" => "c"})
  end

  test "maps FCM responses to job outcomes" do
    capture_log(fn ->
      assert :ok = FCM.classify_response(200, "{}")
      assert :unregistered = FCM.classify_response(404, ~s({"error":{"status":"NOT_FOUND"}}))
      assert {:cancel, _} = FCM.classify_response(400, "{}")
      assert {:error, _} = FCM.classify_response(429, "")
      assert {:error, _} = FCM.classify_response(503, "")
    end)
  end
end
