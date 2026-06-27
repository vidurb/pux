defmodule PuxWeb.RecordControllerTest do
  use PuxWeb.ConnCase, async: true

  test "creates record", %{conn: conn} do
    conn = post(conn, "/api/v1/records")
    assert %{"record_id" => id, "inbox_address" => inbox} = json_response(conn, 201)
    assert is_binary(id)
    assert inbox =~ "@"
  end
end
