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

    Application.put_env(:pux, :fcm,
      enabled: true,
      project_id: "pux-test",
      service_account_json: json
    )

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

  test "ios messages are mutable alerts that expire with the android TTL" do
    now = System.os_time(:second)
    %{message: message} = FCM.message("tok", %{"ciphertext" => "c"})

    assert %{
             headers: %{"apns-push-type" => "alert", "apns-priority" => "10"} = headers,
             payload: %{
               aps: %{
                 alert: %{title: "New code", body: "Open pux to view"},
                 "mutable-content": 1,
                 sound: "default"
               }
             }
           } = message.apns

    expiration = String.to_integer(headers["apns-expiration"])
    assert expiration in (now + 299)..(now + 301)
    refute Map.has_key?(message, :notification)
    assert message.data == %{"ciphertext" => "c"}
  end

  test "maps FCM responses to job outcomes" do
    capture_log(fn ->
      assert :ok = FCM.classify_response(200, "{}")
      assert {:cancel, _} = FCM.classify_response(400, "{}")
      assert {:cancel, _} = FCM.classify_response(403, "{}")
      assert {:error, _} = FCM.classify_response(429, "")
      assert {:error, _} = FCM.classify_response(503, "")
    end)
  end

  describe "what counts as a dead token" do
    @fcm_error "type.googleapis.com/google.firebase.fcm.v1.FcmError"
    @bad_request "type.googleapis.com/google.rpc.BadRequest"

    defp error_body(status, details) do
      Jason.encode!(%{"error" => %{"status" => status, "details" => details}})
    end

    test "a 404 naming UNREGISTERED" do
      body =
        error_body("NOT_FOUND", [%{"@type" => @fcm_error, "errorCode" => "UNREGISTERED"}])

      capture_log(fn -> assert :unregistered = FCM.classify_response(404, body) end)
    end

    test "not any other 404: it could be a wrong project ID or a proxy" do
      capture_log(fn ->
        assert {:error, {:fcm, 404}} = FCM.classify_response(404, error_body("NOT_FOUND", []))
        assert {:error, {:fcm, 404}} = FCM.classify_response(404, "<html>nope</html>")
      end)
    end

    test "a 400 that blames the token field" do
      body =
        error_body("INVALID_ARGUMENT", [
          %{"@type" => @fcm_error, "errorCode" => "INVALID_ARGUMENT"},
          %{"@type" => @bad_request, "fieldViolations" => [%{"field" => "message.token"}]}
        ])

      capture_log(fn -> assert :unregistered = FCM.classify_response(400, body) end)
    end

    test "not a 400 about the payload, which every token would get" do
      body =
        error_body("INVALID_ARGUMENT", [
          %{"@type" => @fcm_error, "errorCode" => "INVALID_ARGUMENT"},
          %{"@type" => @bad_request, "fieldViolations" => [%{"field" => "message.data"}]}
        ])

      capture_log(fn -> assert {:cancel, _} = FCM.classify_response(400, body) end)
    end

    test "not a 403, which wrong server credentials would also cause" do
      body =
        error_body("PERMISSION_DENIED", [
          %{"@type" => @fcm_error, "errorCode" => "SENDER_ID_MISMATCH"}
        ])

      capture_log(fn -> assert {:cancel, _} = FCM.classify_response(403, body) end)
    end
  end
end
