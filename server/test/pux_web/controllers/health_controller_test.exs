defmodule PuxWeb.HealthControllerTest do
  use PuxWeb.ConnCase, async: true

  test "returns ok when database is reachable", %{conn: conn} do
    conn = get(conn, "/health")
    assert %{"status" => "ok"} = json_response(conn, 200)
  end
end
