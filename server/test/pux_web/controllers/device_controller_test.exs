defmodule PuxWeb.DeviceControllerTest do
  use PuxWeb.ConnCase, async: true

  alias Pux.Fixtures
  alias Pux.Records

  setup do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    {:ok, enrollment: enrollment}
  end

  defp auth_conn(conn, record_id) do
    conn
    |> put_req_header("authorization", "Bearer #{record_id}")
    |> put_req_header("content-type", "application/json")
  end

  test "an app whose relay was pruned gets the same 401 as an unknown token", %{
    conn: conn,
    enrollment: enrollment
  } do
    stale = DateTime.utc_now() |> DateTime.add(-31, :day)

    enrollment.record_id
    |> Records.get_record()
    |> Ecto.Changeset.change(last_active_at: stale)
    |> Pux.Repo.update!()

    assert Records.prune_deviceless_records(30) == 1

    params = %{"push_token" => "token-abc", "platform" => "fcm"}
    pruned = conn |> auth_conn(enrollment.record_id) |> post("/api/v1/record/devices", params)
    unknown = conn |> auth_conn(Ecto.UUID.generate()) |> post("/api/v1/record/devices", params)

    assert %{"error" => "unauthorized"} = json_response(pruned, 401)
    assert json_response(pruned, 401) == json_response(unknown, 401)
  end

  test "registers fcm device", %{conn: conn, enrollment: enrollment} do
    conn =
      conn
      |> auth_conn(enrollment.record_id)
      |> post("/api/v1/record/devices", %{
        "push_token" => "token-abc",
        "platform" => "fcm"
      })

    assert %{"device_id" => _, "platform" => "fcm"} = json_response(conn, 201)
  end

  test "registers desktop device", %{conn: conn, enrollment: enrollment} do
    conn =
      conn
      |> auth_conn(enrollment.record_id)
      |> post("/api/v1/record/devices", %{
        "push_token" => "desktop-client-abc",
        "platform" => "desktop"
      })

    assert %{"device_id" => _, "platform" => "desktop"} = json_response(conn, 201)
  end

  test "rejects apns platform", %{conn: conn, enrollment: enrollment} do
    conn =
      conn
      |> auth_conn(enrollment.record_id)
      |> post("/api/v1/record/devices", %{
        "push_token" => "token-abc",
        "platform" => "apns"
      })

    assert %{"error" => "platform must be fcm or desktop"} = json_response(conn, 422)
  end

  test "rejects unauthenticated request", %{conn: conn} do
    conn =
      post(conn, "/api/v1/record/devices", %{
        "push_token" => "token-abc",
        "platform" => "fcm"
      })

    assert json_response(conn, 401)["error"] == "unauthorized"
  end

  defp register(conn, record_id, push_token, platform \\ "fcm") do
    conn
    |> auth_conn(record_id)
    |> post("/api/v1/record/devices", %{
      "push_token" => push_token,
      "platform" => platform
    })
  end

  test "rejects devices over the cap", %{conn: conn, enrollment: enrollment} do
    for i <- 1..10 do
      assert json_response(register(conn, enrollment.record_id, "push-token-#{i}"), 201)
    end

    conn11 = register(conn, enrollment.record_id, "push-token-11")
    assert %{"error" => "too_many_devices"} = json_response(conn11, 422)

    assert %{"device_id" => _} =
             json_response(register(conn, enrollment.record_id, "push-token-1"), 201)
  end

  test "rejects a non-string push_token", %{conn: conn, enrollment: enrollment} do
    for bad <- [%{"a" => "b"}, ["token-abcdef"], 12_345_678] do
      conn = register(conn, enrollment.record_id, bad)
      assert %{"error" => "push_token and platform are required"} = json_response(conn, 422)
    end
  end

  test "rejects a too-short push_token without leaking changeset internals", %{
    conn: conn,
    enrollment: enrollment
  } do
    conn = register(conn, enrollment.record_id, "short")
    assert %{"error" => "push_token must be 8 to 4096 characters"} = json_response(conn, 422)
  end

  test "deletes a device", %{conn: conn, enrollment: enrollment} do
    %{"device_id" => device_id} =
      json_response(register(conn, enrollment.record_id, "token-abc"), 201)

    path = "/api/v1/record/devices/#{device_id}"

    assert response(conn |> auth_conn(enrollment.record_id) |> delete(path), 204)
    assert Records.list_devices(enrollment.record_id) == []

    conn = conn |> auth_conn(enrollment.record_id) |> delete(path)
    assert %{"error" => "not_found"} = json_response(conn, 404)
  end

  test "device deletion is scoped to the authenticated record", %{
    conn: conn,
    enrollment: enrollment
  } do
    {:ok, other} = Records.create_record(Fixtures.public_key())

    %{"device_id" => device_id} =
      json_response(register(conn, enrollment.record_id, "token-abc"), 201)

    conn =
      conn
      |> auth_conn(other.record_id)
      |> delete("/api/v1/record/devices/#{device_id}")

    assert %{"error" => "not_found"} = json_response(conn, 404)
    assert [_] = Records.list_devices(enrollment.record_id)
  end

  test "rejects a malformed device id", %{conn: conn, enrollment: enrollment} do
    conn =
      conn
      |> auth_conn(enrollment.record_id)
      |> delete("/api/v1/record/devices/not-a-uuid")

    assert %{"error" => "not_found"} = json_response(conn, 404)
  end
end
