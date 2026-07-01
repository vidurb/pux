defmodule PuxWeb.Plugs.RecordAuthTest do
  use PuxWeb.ConnCase, async: true

  alias Pux.Records
  alias PuxWeb.Plugs.RecordAuth

  setup do
    {:ok, enrollment} = Records.create_record()
    {:ok, enrollment: enrollment}
  end

  test "authorizes matching bearer token", %{conn: conn, enrollment: enrollment} do
    conn =
      conn
      |> Map.put(:path_params, %{"id" => enrollment.record_id})
      |> put_req_header("authorization", "Bearer #{enrollment.record_id}")
      |> RecordAuth.call(RecordAuth.init([]))

    refute conn.halted
    assert conn.assigns.record_id == enrollment.record_id
  end

  test "rejects mismatched bearer token", %{conn: conn, enrollment: enrollment} do
    {:ok, other} = Records.create_record()

    conn =
      conn
      |> Map.put(:path_params, %{"id" => enrollment.record_id})
      |> put_req_header("authorization", "Bearer #{other.record_id}")
      |> RecordAuth.call(RecordAuth.init([]))

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects missing authorization header", %{conn: conn, enrollment: enrollment} do
    conn =
      conn
      |> Map.put(:path_params, %{"id" => enrollment.record_id})
      |> RecordAuth.call(RecordAuth.init([]))

    assert conn.halted
    assert conn.status == 401
  end
end
