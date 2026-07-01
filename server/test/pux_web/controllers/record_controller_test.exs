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
end
