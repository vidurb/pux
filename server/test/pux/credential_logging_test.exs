defmodule Pux.CredentialLoggingTest do
  @moduledoc """
  The record ID is the only credential for a relay, and the inbox token and push tokens
  identify one. None of them may reach the logs, directly or through `inspect/1`, an
  exit reason or a crash report.

  `config/test.exs` sets the level to `:warning`, so these tests raise it to `:info`, the
  level production runs at. Not `:debug`: Ecto logs query parameters there, which is why
  `config/prod.exs` must never go below `:info`.
  """
  use Pux.DataCase, async: false
  use Oban.Testing, repo: Pux.Repo

  import ExUnit.CaptureLog

  alias Pux.{Fixtures, Push, Records}
  alias Pux.Push.{APNs, FCM}
  alias Pux.Records.{Device, PendingDelivery, Record}
  alias Pux.SMTP.Session
  alias Pux.Workers.PushWorker

  @smtp_port Application.compile_env!(:pux, [:smtp, :port])

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    {:ok, enrollment: enrollment, record: Records.get_record(enrollment.record_id)}
  end

  describe "delivery failures" do
    test "encryption failure", %{enrollment: e, record: record} do
      log =
        capture_log(fn ->
          assert :ok = Push.deliver_to_record(%{record | public_key: <<1, 2, 3>>}, "{}")
        end)

      assert log =~ "Push encryption failed: :invalid_public_key"
      refute_credentials(log, e)
    end

    test "pending delivery failure when the record is deleted mid-delivery", %{
      enrollment: e,
      record: record
    } do
      {:ok, _} = add_device(e, :desktop)
      on_insert("pending_deliveries", "DELETE FROM records WHERE id = NEW.record_id; RETURN NEW;")

      log = capture_log(fn -> assert :ok = Push.deliver_to_record(record, "{}") end)

      assert log =~ "Pending delivery persistence failed: record_id does not exist"
      refute_credentials(log, e)
      refute log =~ "ciphertext"
    end

    test "database failure during SMTP delivery", %{enrollment: e} do
      {:ok, _} = add_device(e, :desktop)
      on_insert("pending_deliveries", "RAISE EXCEPTION 'database failure';")

      body = "From: a@hdfcbank.net\r\nTo: #{e.inbox_address}\r\n\r\nYour OTP is 482913\r\n"

      log =
        capture_log(fn ->
          assert {:error, :send, {:temporary_failure, _, "451 4.3.0" <> _}} =
                   :gen_smtp_client.send_blocking({"a@hdfcbank.net", [e.inbox_address], body},
                     relay: "127.0.0.1",
                     port: @smtp_port,
                     tls: :never,
                     auth: :never,
                     hostname: "t.local",
                     retries: 0
                   )

          # A crash would be reported from other processes, after the client sees the close.
          Process.sleep(100)
        end)

      assert log =~ "SMTP: command failed (Postgrex.Error)"
      refute log =~ "terminating"
      refute_credentials(log, e)
      refute log =~ "482913"
    end

    test "database failure on RCPT doesn't log the address", %{enrollment: e} do
      {:ok, _banner, state} = Session.init("pux.test", 0, {127, 0, 0, 1}, mail_domain: "pux.test")
      # Postgres refuses a NUL byte in a text parameter, so the lookup raises.
      address = "#{e.inbox_token}\0@pux.test"

      log =
        capture_log(fn ->
          assert {:error, "451 4.3.0" <> _, ^state} = Session.handle_RCPT(address, state)
        end)

      assert log =~ "SMTP: command failed"
      refute_credentials(log, e)
    end

    test "classification crash doesn't log the message", %{enrollment: e} do
      {:ok, _banner, state} = Session.init("pux.test", 0, {127, 0, 0, 1}, mail_domain: "pux.test")
      # A non-binary envelope sender makes Inbound.classify/2 raise on a mail with no From.
      {:ok, state} = Session.handle_MAIL(123, state)
      {:ok, state} = Session.handle_RCPT(e.inbox_address, state)
      body = "To: #{e.inbox_address}\r\n\r\nYour OTP is 482913\r\n"

      log =
        capture_log(fn ->
          assert {:ok, "250 OK", _} = Session.handle_DATA(123, [e.inbox_address], body, state)
        end)

      assert log =~ "classification failed"
      assert log =~ "FunctionClauseError"
      refute_credentials(log, e)
      refute log =~ "482913"
    end
  end

  describe "inspect/1, which crash reports and error logs rely on" do
    test "records and their changesets", %{enrollment: e, record: record} do
      attrs = %{inbox_token: e.inbox_token, public_key: record.public_key}

      for term <- [
            record,
            %{recipients: [record]},
            Record.changeset(%Record{}, attrs),
            Ecto.Changeset.change(record, last_active_at: DateTime.utc_now())
          ] do
        inspected = inspect(term)
        refute_credentials(inspected, e)
        refute inspected =~ inspect(record.public_key)
      end
    end

    test "devices and pending deliveries", %{enrollment: e} do
      {:ok, device} = add_device(e, :fcm)
      {:ok, pending} = Pux.Deliveries.create_pending(e.record_id, %{"ciphertext" => "c"})

      for term <- [
            device,
            pending,
            Device.changeset(%Device{}, %{
              record_id: e.record_id,
              push_token: device.push_token,
              platform: :fcm,
              last_seen_at: DateTime.utc_now()
            }),
            PendingDelivery.changeset(%PendingDelivery{}, %{
              record_id: e.record_id,
              envelope: %{"ciphertext" => "c"}
            })
          ] do
        inspected = inspect(term)
        refute_credentials(inspected, e)
        refute inspected =~ device.push_token
      end
    end
  end

  describe "push" do
    test "job args carry no credentials", %{enrollment: e, record: record} do
      {:ok, device} = add_device(e, :fcm)

      assert :ok = Push.deliver_to_record(record, "{}")

      assert [%{args: args}] = all_enqueued(worker: PushWorker)
      assert args["device_id"] == device.id
      refute_credentials(inspect(args), e)
      refute inspect(args) =~ device.push_token
    end

    test "disabled providers don't log any of the push token" do
      token = "pushtoken-that-is-long-enough"

      for module <- [FCM, APNs] do
        Logger.put_module_level(module, :debug)
        on_exit(fn -> Logger.delete_module_level(module) end)

        log = capture_log(fn -> assert :ok = module.deliver(token, %{"ciphertext" => "c"}) end)

        assert log =~ "would push"
        refute log =~ String.slice(token, 0, 8)
      end
    end
  end

  test "an invalid FCM service account doesn't log the private key" do
    config = Application.get_env(:pux, :fcm)
    on_exit(fn -> Application.put_env(:pux, :fcm, config) end)

    Application.put_env(:pux, :fcm,
      enabled: true,
      project_id: "p",
      service_account_json: ~s({"private_key": "secret-key" oops})
    )

    log = capture_log(fn -> assert FCM.goth_child_spec() == nil end)

    assert log =~ "FCM service account JSON is invalid"
    refute log =~ "secret-key"
  end

  describe "HTTP" do
    test "API requests are logged without the credential on every route", %{enrollment: e} do
      {:ok, device} = add_device(e, :desktop)
      {:ok, pending} = Pux.Deliveries.create_pending(e.record_id, %{"ciphertext" => "c"})
      body = ~s({"push_token":"push-token-http","platform":"fcm"})

      log =
        capture_log(fn ->
          assert %{status: 201} = api(e, :post, "/devices", body)
          assert %{status: 200} = api(e, :get, "/deliveries")
          assert %{status: 204} = api(e, :delete, "/deliveries/#{pending.id}")
          assert %{status: 204} = api(e, :delete, "/devices/#{device.id}")
          assert %{status: 204} = api(e, :delete, "")
        end)

      assert log =~ "POST /api/v1/record/devices"
      assert log =~ "GET /api/v1/record/deliveries"
      assert log =~ "DELETE /api/v1/record/deliveries/#{pending.id}"
      assert log =~ "DELETE /api/v1/record/devices/#{device.id}"
      assert log =~ "DELETE /api/v1/record\n"
      refute log =~ "push-token-http"
      refute_credentials(log, e)
    end

    test "rejected tokens aren't logged", %{enrollment: e} do
      unknown = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          for token <- [unknown, "malformed-credential", e.record_id <> "x"] do
            assert %{status: 401} = api(%{record_id: token}, :get, "/deliveries")
          end
        end)

      assert log =~ "Sent 401"
      refute log =~ unknown
      refute log =~ "malformed-credential"
      refute_credentials(log, e)
    end

    test "a rate limited request doesn't log the credential", %{enrollment: e} do
      config = Application.get_env(:pux, :record_rate_limit)
      on_exit(fn -> Application.put_env(:pux, :record_rate_limit, config) end)
      Application.put_env(:pux, :record_rate_limit, limit: 1, scale_ms: 60_000)

      log =
        capture_log(fn ->
          assert %{status: 200} = api(e, :get, "/deliveries")
          assert %{status: 429} = api(e, :get, "/deliveries")
        end)

      assert log =~ "Record API rate limit exceeded"
      refute_credentials(log, e)
    end

    test "a 500 doesn't log the credential", %{enrollment: e} do
      on_insert("devices", "RAISE EXCEPTION 'database failure';")

      log =
        capture_log(fn ->
          body = ~s({"push_token":"push-token-http","platform":"fcm"})
          assert %{status: 500} = api(e, :post, "/devices", body)
          # Bandit logs the exception after it has sent the response.
          Process.sleep(200)
        end)

      assert log =~ "Postgrex.Error"
      refute log =~ "push-token-http"
      refute_credentials(log, e)
    end

    test "a database failure while authenticating doesn't log the credential", %{enrollment: e} do
      # Rolled back with the sandbox transaction.
      Pux.Repo.query!("ALTER TABLE records RENAME TO records_hidden")

      log =
        capture_log(fn ->
          assert %{status: 500} = api(e, :get, "/deliveries")
          Process.sleep(200)
        end)

      assert log =~ "Postgrex.Error"
      refute_credentials(log, e)
    end

    test "the HTTPS redirect logs nothing and carries no credential", %{enrollment: e} do
      force_ssl =
        "../../config/prod.exs"
        |> Path.expand(__DIR__)
        |> Config.Reader.read!(env: :prod)
        |> get_in([:pux, PuxWeb.Endpoint, :force_ssl])

      conn =
        :get
        |> Plug.Test.conn("http://pux.test/api/v1/record/deliveries")
        |> Plug.Conn.put_req_header("x-forwarded-proto", "http")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{e.record_id}")

      log =
        capture_log(fn ->
          conn = Plug.SSL.call(conn, Plug.SSL.init(force_ssl))
          assert conn.status == 301

          assert Plug.Conn.get_resp_header(conn, "location") ==
                   ["https://pux.test/api/v1/record/deliveries"]
        end)

      assert log == ""
    end
  end

  describe "delivery socket" do
    test "connecting doesn't log the token", %{enrollment: e} do
      log =
        capture_log(fn ->
          assert ws_upgrade_status(e.record_id) == "101"
          assert ws_upgrade_status(Ecto.UUID.generate()) == "403"
        end)

      refute_credentials(log, e)
    end

    test "the socket process doesn't hold the record ID", %{enrollment: e} do
      {:ok, state} = PuxWeb.DeliverySocket.init(%{record_id: e.record_id})

      refute_credentials(inspect(state), e)
    end
  end

  defp refute_credentials(text, enrollment) do
    refute text =~ enrollment.record_id
    refute text =~ String.replace(enrollment.record_id, "-", "")
    refute text =~ enrollment.inbox_token
  end

  defp add_device(enrollment, platform) do
    Records.register_device(enrollment.record_id, %{
      push_token: "push-token-#{System.unique_integer([:positive])}",
      platform: platform
    })
  end

  # Rolled back with the sandbox transaction, like everything else in the test.
  defp on_insert(table, body) do
    Pux.Repo.query!("""
    CREATE FUNCTION credential_logging_test() RETURNS trigger AS $$
    BEGIN #{body} END;
    $$ LANGUAGE plpgsql
    """)

    Pux.Repo.query!("""
    CREATE TRIGGER credential_logging_test BEFORE INSERT ON #{table}
    FOR EACH ROW EXECUTE FUNCTION credential_logging_test()
    """)
  end

  defp http_port, do: Application.fetch_env!(:pux, PuxWeb.Endpoint)[:http][:port]

  defp api(enrollment, method, path, body \\ nil) do
    url = "http://127.0.0.1:#{http_port()}/api/v1/record#{path}"

    headers = [
      {"authorization", "Bearer #{enrollment.record_id}"},
      {"content-type", "application/json"}
    ]

    {:ok, response} = method |> Finch.build(url, headers, body) |> Finch.request(Pux.Finch)
    response
  end

  defp ws_upgrade_status(token) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", http_port(), [:binary, active: false])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(socket, [
        "GET /ws/delivery HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n",
        "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n",
        "Sec-WebSocket-Key: #{key}\r\nx-pux-token: #{token}\r\n\r\n"
      ])

    {:ok, "HTTP/1.1 " <> <<status::binary-size(3), _::binary>>} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    status
  end
end
