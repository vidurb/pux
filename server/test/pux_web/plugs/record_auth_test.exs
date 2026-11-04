defmodule PuxWeb.Plugs.RecordAuthTest do
  use PuxWeb.ConnCase, async: true

  alias Pux.Fixtures
  alias Pux.Records
  alias PuxWeb.Plugs.RecordAuth

  @routes [
    {:delete, "/api/v1/record"},
    {:post, "/api/v1/record/devices"},
    {:delete, "/api/v1/record/devices/#{Ecto.UUID.generate()}"},
    {:get, "/api/v1/record/deliveries"},
    {:delete, "/api/v1/record/deliveries/#{Ecto.UUID.generate()}"}
  ]

  setup do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    {:ok, enrollment: enrollment}
  end

  defp authorize(conn, header) do
    conn
    |> put_req_header("authorization", header)
    |> RecordAuth.call(RecordAuth.init([]))
  end

  test "identifies the record from the bearer token", %{conn: conn, enrollment: enrollment} do
    conn = authorize(conn, "Bearer #{enrollment.record_id}")

    refute conn.halted
    assert conn.assigns.record_id == enrollment.record_id
  end

  test "assigns the stored ID whatever case the token is in", %{
    conn: conn,
    enrollment: enrollment
  } do
    conn = authorize(conn, "Bearer #{String.upcase(enrollment.record_id)}")

    refute conn.halted
    assert conn.assigns.record_id == enrollment.record_id
  end

  test "ignores any record ID outside the header", %{conn: conn, enrollment: enrollment} do
    {:ok, other} = Records.create_record(Fixtures.public_key())

    conn =
      conn
      |> Map.put(:path_params, %{"id" => other.record_id})
      |> Map.put(:params, %{"id" => other.record_id, "record_id" => other.record_id})
      |> authorize("Bearer #{enrollment.record_id}")

    assert conn.assigns.record_id == enrollment.record_id

    conn =
      build_conn()
      |> Map.put(:params, %{"id" => other.record_id})
      |> RecordAuth.call(RecordAuth.init([]))

    assert conn.status == 401
  end

  describe "every authenticated route" do
    test "answers bad credentials identically, without revealing whether a record exists", %{
      conn: conn,
      enrollment: enrollment
    } do
      {:ok, deleted} = Records.create_record(Fixtures.public_key())
      :ok = Records.delete_record(deleted.record_id)
      # Exercised against a real record's ID, so a wrong scheme can't pass as a valid one.
      id = enrollment.record_id

      bad_headers = [
        nil,
        "",
        "Bearer ",
        "Bearer not-a-uuid",
        "Bearer #{id}x",
        "Bearer #{String.replace(id, "-", "")}",
        "Bearer #{binary_part(Ecto.UUID.bingenerate(), 0, 16)}",
        "bearer #{id}",
        "Basic #{id}",
        id,
        "Bearer #{Ecto.UUID.generate()}",
        "Bearer #{deleted.record_id}"
      ]

      for {method, path} <- @routes, header <- bad_headers do
        conn = if header, do: put_req_header(conn, "authorization", header), else: conn
        conn = dispatch(conn, @endpoint, method, path)

        assert conn.status == 401, "#{method} #{path} with #{inspect(header)}"
        assert conn.resp_body == ~s({"error":"unauthorized"})
        assert ["application/json" <> _] = get_resp_header(conn, "content-type")
        assert response_headers(conn) == response_headers(reference_401(method, path))
      end

      assert Records.get_record(id)
    end

    test "doesn't let one token reach another record", %{conn: conn, enrollment: enrollment} do
      {:ok, other} = Records.create_record(Fixtures.public_key())
      {:ok, pending} = Pux.Deliveries.create_pending(enrollment.record_id, %{"ciphertext" => "c"})

      listed =
        conn
        |> put_req_header("authorization", "Bearer #{other.record_id}")
        |> get("/api/v1/record/deliveries")

      assert json_response(listed, 200) == %{"deliveries" => []}

      acked =
        conn
        |> put_req_header("authorization", "Bearer #{other.record_id}")
        |> delete("/api/v1/record/deliveries/#{pending.id}")

      assert json_response(acked, 404) == %{"error" => "not_found"}
      assert [_] = Pux.Deliveries.list_pending(enrollment.record_id)
    end
  end

  test "the old routes with the record ID in the path are gone", %{
    conn: conn,
    enrollment: enrollment
  } do
    id = enrollment.record_id
    conn = put_req_header(conn, "authorization", "Bearer #{id}")

    for {method, path} <- [
          {:delete, "/api/v1/records/#{id}"},
          {:post, "/api/v1/records/#{id}/devices"},
          {:delete, "/api/v1/records/#{id}/devices/#{Ecto.UUID.generate()}"},
          {:get, "/api/v1/records/#{id}/deliveries"},
          {:delete, "/api/v1/records/#{id}/deliveries/#{Ecto.UUID.generate()}"}
        ] do
      assert dispatch(conn, @endpoint, method, path).status == 404
    end

    assert Records.get_record(id)
  end

  defp reference_401(method, path), do: dispatch(build_conn(), @endpoint, method, path)

  defp response_headers(conn), do: conn.resp_headers |> Enum.map(&elem(&1, 0)) |> Enum.sort()
end
