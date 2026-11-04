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

  describe "failed authentication limit" do
    setup do
      test_pid = self()
      handler = "record-auth-queries-#{System.unique_integer()}"

      :telemetry.attach(handler, [:pux, :repo, :query], &__MODULE__.notify_query/4, test_pid)
      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, limit: [key: "test_auth_failure:#{System.unique_integer()}", scale_ms: 60_000]}
    end

    defp attempt(conn, token, limit) do
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> RecordAuth.call(RecordAuth.init(limit))
    end

    defp fail_times(conn, times, limit) do
      for _ <- 1..times, do: assert(attempt(conn, Ecto.UUID.generate(), limit).status == 401)
      flush_queries()
    end

    test "answers 429 without a query once the limit is reached, whatever the token", %{
      conn: conn,
      enrollment: enrollment,
      limit: limit
    } do
      limit = [{:limit, 2} | limit]
      fail_times(conn, 2, limit)

      unknown = attempt(conn, Ecto.UUID.generate(), limit)
      valid = attempt(conn, enrollment.record_id, limit)
      refute_received {:query, _}

      for conn <- [unknown, valid] do
        assert conn.halted
        assert conn.status == 429
        assert conn.resp_body == ~s({"error":"rate_limit_exceeded"})
        assert ["application/json" <> _] = get_resp_header(conn, "content-type")
        refute Map.has_key?(conn.assigns, :record_id)
      end

      assert response_headers(unknown) == response_headers(valid)
    end

    test "still looks up tokens under the limit", %{conn: conn, limit: limit} do
      assert attempt(conn, Ecto.UUID.generate(), [{:limit, 2} | limit]).status == 401
      assert_received {:query, _}
    end

    test "doesn't count requests that authenticate", %{
      conn: conn,
      enrollment: enrollment,
      limit: limit
    } do
      limit = [{:limit, 2} | limit]

      for _ <- 1..5 do
        conn = attempt(conn, enrollment.record_id, limit)
        refute conn.halted
        assert conn.assigns.record_id == enrollment.record_id
      end

      fail_times(conn, 2, limit)
      assert attempt(conn, Ecto.UUID.generate(), limit).status == 429
    end

    test "malformed tokens stop before the database and don't count", %{
      conn: conn,
      enrollment: enrollment,
      limit: limit
    } do
      limit = [{:limit, 1} | limit]

      for _ <- 1..3, token <- ["not-a-uuid", "#{enrollment.record_id}x"] do
        assert attempt(conn, token, limit).status == 401
      end

      for _ <- 1..3 do
        assert RecordAuth.call(conn, RecordAuth.init(limit)).status == 401
      end

      refute_received {:query, _}
      assert attempt(conn, enrollment.record_id, limit).assigns.record_id == enrollment.record_id

      # Over the limit a malformed token still gets its 401, since it costs nothing.
      fail_times(conn, 1, limit)
      assert attempt(conn, Ecto.UUID.generate(), limit).status == 429
      assert attempt(conn, "not-a-uuid", limit).status == 401
    end

    test "counts per client IP, which a public peer can't change", %{conn: conn, limit: limit} do
      limit = [{:limit, 1} | limit]

      from = fn ip, xff ->
        conn |> Map.put(:remote_ip, ip) |> put_req_header("x-forwarded-for", xff)
      end

      fail_times(from.({198, 51, 100, 2}, "1.1.1.1"), 1, limit)

      assert attempt(from.({198, 51, 100, 2}, "2.2.2.2"), Ecto.UUID.generate(), limit).status ==
               429

      assert attempt(from.({198, 51, 100, 3}, "2.2.2.2"), Ecto.UUID.generate(), limit).status ==
               401

      fail_times(from.({10, 0, 0, 1}, "1.1.1.1, 203.0.113.7"), 1, limit)

      assert attempt(from.({10, 0, 0, 1}, "203.0.113.7"), Ecto.UUID.generate(), limit).status ==
               429

      assert attempt(from.({10, 0, 0, 1}, "203.0.113.8"), Ecto.UUID.generate(), limit).status ==
               401
    end

    test "clears in a new window", %{conn: conn, enrollment: enrollment, limit: limit} do
      limit = Keyword.merge(limit, limit: 1, scale_ms: 50)
      fail_times(conn, 1, limit)
      assert attempt(conn, enrollment.record_id, limit).status == 429

      Process.sleep(110)
      assert attempt(conn, enrollment.record_id, limit).assigns.record_id == enrollment.record_id
    end
  end

  def notify_query(_event, _measurements, _metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:query, :records})
  end

  defp flush_queries do
    receive do
      {:query, _} -> flush_queries()
    after
      0 -> :ok
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
