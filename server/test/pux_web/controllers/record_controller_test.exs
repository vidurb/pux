defmodule PuxWeb.RecordControllerTest do
  use PuxWeb.ConnCase, async: true

  alias Pux.Fixtures

  test "creates record with client public key", %{conn: conn} do
    public_key = Fixtures.public_key_b64()

    conn = post(conn, "/api/v1/records", %{"public_key" => public_key})

    response = json_response(conn, 201)

    assert %{
             "record_id" => id,
             "inbox_address" => inbox,
             "public_key" => ^public_key
           } = response

    assert is_binary(id)
    assert inbox =~ "@"
    refute Map.has_key?(response, "private_key")
  end

  test "rejects missing public key", %{conn: conn} do
    conn = post(conn, "/api/v1/records", %{})
    assert %{"error" => "invalid public_key"} = json_response(conn, 422)
  end

  test "rejects invalid public key", %{conn: conn} do
    conn = post(conn, "/api/v1/records", %{"public_key" => "not-a-key"})
    assert %{"error" => "invalid public_key"} = json_response(conn, 422)
  end

  test "deletes a record with its devices and pending deliveries", %{conn: conn} do
    {:ok, enrollment} = Pux.Records.create_record(Fixtures.public_key())
    id = enrollment.record_id

    {:ok, _} = Pux.Records.register_device(id, %{push_token: "desktop-1", platform: :desktop})
    {:ok, _} = Pux.Deliveries.create_pending(id, %{"ciphertext" => "x"})

    deleted =
      conn
      |> put_req_header("authorization", "Bearer #{id}")
      |> delete("/api/v1/record")

    assert response(deleted, 204)
    refute Pux.Records.get_record(id)
    assert Pux.Records.list_devices(id) == []
    assert Pux.Deliveries.list_pending(id) == []
  end

  test "rejects unauthenticated record deletion", %{conn: conn} do
    {:ok, enrollment} = Pux.Records.create_record(Fixtures.public_key())

    conn = delete(conn, "/api/v1/record")
    assert json_response(conn, 401)["error"] == "unauthorized"
    assert Pux.Records.get_record(enrollment.record_id)
  end
end
