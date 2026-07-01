defmodule PuxWeb.DeviceControllerTest do
  use PuxWeb.ConnCase, async: true

  alias Pux.Records

  setup do
    {:ok, enrollment} = Records.create_record()
    {:ok, enrollment: enrollment}
  end

  defp auth_conn(conn, record_id) do
    conn
    |> put_req_header("authorization", "Bearer #{record_id}")
    |> put_req_header("content-type", "application/json")
  end

  test "registers fcm device", %{conn: conn, enrollment: enrollment} do
    conn =
      conn
      |> auth_conn(enrollment.record_id)
      |> post("/api/v1/records/#{enrollment.record_id}/devices", %{
        "push_token" => "token-abc",
        "platform" => "fcm"
      })

    assert %{"device_id" => _, "platform" => "fcm"} = json_response(conn, 201)
  end

  test "rejects apns platform", %{conn: conn, enrollment: enrollment} do
    conn =
      conn
      |> auth_conn(enrollment.record_id)
      |> post("/api/v1/records/#{enrollment.record_id}/devices", %{
        "push_token" => "token-abc",
        "platform" => "apns"
      })

    assert %{"error" => "platform must be fcm"} = json_response(conn, 422)
  end

  test "rejects unauthenticated request", %{conn: conn, enrollment: enrollment} do
    conn =
      post(conn, "/api/v1/records/#{enrollment.record_id}/devices", %{
        "push_token" => "token-abc",
        "platform" => "fcm"
      })

    assert json_response(conn, 401)["error"] == "unauthorized"
  end
end
