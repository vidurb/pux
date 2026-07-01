defmodule PuxWeb.DeliveryControllerTest do
  use PuxWeb.ConnCase, async: true

  alias Pux.{Deliveries, Fixtures, Records}

  setup do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    {:ok, enrollment: enrollment}
  end

  defp auth_conn(conn, record_id) do
    conn
    |> put_req_header("authorization", "Bearer #{record_id}")
    |> put_req_header("content-type", "application/json")
  end

  test "lists pending deliveries", %{conn: conn, enrollment: enrollment} do
    {:ok, pending} =
      Deliveries.create_pending(enrollment.record_id, %{"ciphertext" => "abc123"})

    conn =
      conn
      |> auth_conn(enrollment.record_id)
      |> get("/api/v1/records/#{enrollment.record_id}/deliveries")

    assert %{"deliveries" => [delivery]} = json_response(conn, 200)
    assert delivery["delivery_id"] == pending.id
    assert delivery["envelope"]["ciphertext"] == "abc123"
  end

  test "acks pending delivery", %{conn: conn, enrollment: enrollment} do
    {:ok, pending} =
      Deliveries.create_pending(enrollment.record_id, %{"ciphertext" => "abc123"})

    conn =
      conn
      |> auth_conn(enrollment.record_id)
      |> delete("/api/v1/records/#{enrollment.record_id}/deliveries/#{pending.id}")

    assert response(conn, 204)
    assert Deliveries.list_pending(enrollment.record_id) == []
  end

  test "rejects unauthenticated request", %{conn: conn, enrollment: enrollment} do
    conn = get(conn, "/api/v1/records/#{enrollment.record_id}/deliveries")
    assert json_response(conn, 401)["error"] == "unauthorized"
  end
end
