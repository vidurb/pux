defmodule Pux.SMTP.SessionTest do
  use Pux.DataCase, async: true
  use Oban.Testing, repo: Pux.Repo

  alias Pux.{DKIMSigner, DKIMTestResolver, Fixtures, Records}
  alias Pux.SMTP.Session
  alias Pux.Workers.PushWorker

  import ExUnit.CaptureLog

  @otp_mail "From: hsbc@hsbc.bank.in\r\nSubject: OTP\r\n\r\nYour OTP is 482913\r\n"

  setup do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    {:ok, _banner, state} = Session.init("pux.test", 0, {127, 0, 0, 1}, mail_domain: "pux.test")
    {:ok, state} = Session.handle_MAIL("sender@bank.com", state)
    {:ok, state: state, enrollment: enrollment}
  end

  test "accepts a known inbox on the configured mail domain", %{state: state, enrollment: e} do
    with_device(e)
    assert {:ok, %{recipients: [record]}} = Session.handle_RCPT(e.inbox_address, state)
    assert record.id == e.record_id
  end

  test "rejects recipient on wrong mail domain", %{state: state, enrollment: e} do
    assert {:error, "550 " <> _, ^state} =
             Session.handle_RCPT("#{e.inbox_token}@wrong.example", state)
  end

  test "rejects unknown inbox token", %{state: state} do
    assert {:error, "550 " <> _, ^state} = Session.handle_RCPT("abcdefgh12345678@pux.test", state)
  end

  test "deduplicates repeated recipients", %{state: state, enrollment: e} do
    with_device(e)
    {:ok, state} = Session.handle_RCPT(e.inbox_address, state)
    assert {:ok, %{recipients: [_]}} = Session.handle_RCPT(String.upcase(e.inbox_address), state)
  end

  test "banner names the host" do
    assert {:ok, "mx.pux.test ESMTP pux", _} = Session.init("mx.pux.test", 0, {127, 0, 0, 1}, [])
  end

  test "caps connections per IP" do
    registry = :"smtp_test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: registry})
    opts = [registry: registry, max_connections_per_ip: 1]

    assert {:ok, _, _} = Session.init("h", 0, {10, 0, 0, 9}, opts)

    task =
      Task.async(fn -> Session.init("h", 0, {10, 0, 0, 9}, opts) end)

    assert {:stop, :normal, "421 " <> _} = Task.await(task)
  end

  describe "the per-IP connection limit" do
    setup do
      registry = :"smtp_test_registry_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: registry})
      {:ok, registry: registry}
    end

    # Each init/4 registers the calling process, so a second connection needs its own.
    defp init_elsewhere(address, opts) do
      fn -> Session.init("h", 0, address, opts) end |> Task.async() |> Task.await()
    end

    test "counts an IPv6 /64 as one client", %{registry: registry} do
      opts = [registry: registry, max_connections_per_ip: 1]

      assert {:ok, _, _} = Session.init("h", 0, {0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}, opts)

      assert {:stop, :normal, "421 " <> _} =
               init_elsewhere({0x2001, 0xDB8, 1, 2, 0xA, 0xB, 0xC, 0xD}, opts)

      assert {:ok, _, _} = init_elsewhere({0x2001, 0xDB8, 1, 3, 0, 0, 0, 1}, opts)
    end

    test "counts an IPv4-mapped IPv6 peer as its IPv4 address", %{registry: registry} do
      opts = [registry: registry, max_connections_per_ip: 1]

      assert {:ok, _, _} = Session.init("h", 0, {203, 0, 113, 7}, opts)

      assert {:stop, :normal, "421 " <> _} =
               init_elsewhere({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}, opts)
    end

    test "is off at 0", %{registry: registry} do
      opts = [registry: registry, max_connections_per_ip: 0]

      for _ <- 1..3 do
        assert {:ok, _, _} = init_elsewhere({10, 0, 0, 9}, opts)
      end

      assert {:ok, _, _} = Session.init("h", 0, {10, 0, 0, 9}, opts)
      assert Registry.count(registry) == 0
    end
  end

  defp with_device(enrollment) do
    {:ok, device} =
      Records.register_device(enrollment.record_id, %{
        push_token: "fcm-token-#{System.unique_integer([:positive])}",
        platform: :fcm
      })

    device
  end

  defp session(opts) do
    {:ok, _banner, state} =
      Session.init("pux.test", 0, {127, 0, 0, 1}, [mail_domain: "pux.test"] ++ opts)

    state
  end

  defp deliver(state, enrollment, data \\ @otp_mail) do
    {:ok, state} = Session.handle_MAIL("sender@bank.com", state)
    {:ok, state} = Session.handle_RCPT(enrollment.inbox_address, state)

    {:ok, "250 OK", state} =
      Session.handle_DATA("sender@bank.com", [enrollment.inbox_address], data, state)

    state
  end

  test "delivers an OTP to each recipient", %{enrollment: e} do
    device = with_device(e)
    deliver(session([]), e)
    assert_enqueued(worker: PushWorker, args: %{"device_id" => device.id})
  end

  test "rate limits deliveries per record but still answers 250", %{enrollment: e} do
    device = with_device(e)
    state = session(inbound_rate_limit: 2, inbound_rate_scale_ms: 60_000)

    Enum.reduce(1..3, state, fn _, s -> deliver(s, e) end)

    assert length(all_enqueued(worker: PushWorker, args: %{"device_id" => device.id})) == 2
  end

  test "a record deleted while mail is in flight doesn't crash the session", %{enrollment: e} do
    with_device(e)
    state = session([])
    {:ok, state} = Session.handle_RCPT(e.inbox_address, state)
    Pux.Repo.delete!(Records.get_record(e.record_id))

    assert {:ok, "250 OK", _} =
             Session.handle_DATA("sender@bank.com", [e.inbox_address], @otp_mail, state)
  end

  describe "a relay with no devices" do
    @rejected "550 5.1.1 Recipient rejected"

    defp new_relay do
      {:ok, enrollment} = Records.create_record(Fixtures.public_key())
      enrollment
    end

    defp age_record(record_id) do
      stale = DateTime.utc_now() |> DateTime.add(-20, :day)

      record_id
      |> Records.get_record()
      |> Ecto.Changeset.change(last_active_at: stale)
      |> Pux.Repo.update!()

      stale
    end

    test "gets the same permanent reply as an unknown address", %{state: state, enrollment: e} do
      assert {:error, @rejected, ^state} = Session.handle_RCPT(e.inbox_address, state)

      assert {:error, @rejected, ^state} =
               Session.handle_RCPT("abcdefgh12345678@pux.test", state)
    end

    test "is rejected but kept during its grace period", %{state: state, enrollment: e} do
      device = with_device(e)
      assert {:ok, _} = Session.handle_RCPT(e.inbox_address, state)

      assert Records.delete_devices_by_token(device.push_token) == 1

      assert {:error, @rejected, _} = Session.handle_RCPT(e.inbox_address, state)
      assert Records.get_record(e.record_id)
    end

    test "takes mail again as soon as a device re-registers", %{state: state, enrollment: e} do
      device = with_device(e)
      Records.delete_devices_by_token(device.push_token)
      assert {:error, @rejected, _} = Session.handle_RCPT(e.inbox_address, state)

      {:ok, back} =
        Records.register_device(e.record_id, %{push_token: device.push_token, platform: :fcm})

      deliver(session([]), e)
      assert_enqueued(worker: PushWorker, args: %{"device_id" => back.id})
    end

    test "a rejection doesn't restart its clock", %{state: state, enrollment: e} do
      stale = age_record(e.record_id)

      assert {:error, @rejected, _} = Session.handle_RCPT(e.inbox_address, state)

      last_active_at = Records.get_record(e.record_id).last_active_at
      assert DateTime.compare(last_active_at, stale) == :eq
    end

    test "losing the last device after RCPT drops the mail without restarting the clock", %{
      state: state,
      enrollment: e
    } do
      device = with_device(e)
      {:ok, state} = Session.handle_RCPT(e.inbox_address, state)
      Records.delete_devices_by_token(device.push_token)
      stale = age_record(e.record_id)

      assert {:ok, "250 OK", _} =
               Session.handle_DATA("sender@bank.com", [e.inbox_address], @otp_mail, state)

      last_active_at = Records.get_record(e.record_id).last_active_at
      assert DateTime.compare(last_active_at, stale) == :eq
      refute_enqueued(worker: PushWorker)
    end

    test "in a multi-recipient message only that recipient is refused", %{
      state: state,
      enrollment: e
    } do
      device = with_device(e)
      deviceless = new_relay()

      {:ok, state} = Session.handle_RCPT(e.inbox_address, state)
      assert {:error, @rejected, state} = Session.handle_RCPT(deviceless.inbox_address, state)
      assert [%{id: id}] = state.recipients
      assert id == e.record_id

      assert {:ok, "250 OK", _} =
               Session.handle_DATA("sender@bank.com", [e.inbox_address], @otp_mail, state)

      assert [_] = all_enqueued(worker: PushWorker, args: %{"device_id" => device.id})
    end

    test "doesn't use up the recipient limit", %{enrollment: e} do
      with_device(e)
      deviceless = new_relay()

      {:ok, _banner, state} =
        Session.init("pux.test", 0, {127, 0, 0, 1}, mail_domain: "pux.test", max_recipients: 1)

      {:ok, state} = Session.handle_MAIL("sender@bank.com", state)

      assert {:error, @rejected, state} = Session.handle_RCPT(deviceless.inbox_address, state)
      assert {:ok, %{recipients: [_]}} = Session.handle_RCPT(e.inbox_address, state)
    end

    test "is refused whatever the rate limit says, and doesn't spend it", %{enrollment: e} do
      state = session(inbound_rate_limit: 1, inbound_rate_scale_ms: 60_000)
      {:ok, state} = Session.handle_MAIL("sender@bank.com", state)

      for _ <- 1..3 do
        assert {:error, @rejected, _} = Session.handle_RCPT(e.inbox_address, state)
      end

      device = with_device(e)
      deliver(session(inbound_rate_limit: 1, inbound_rate_scale_ms: 60_000), e)
      assert [_] = all_enqueued(worker: PushWorker, args: %{"device_id" => device.id})
    end
  end

  test "mail with a device to go to restarts the relay's clock", %{enrollment: e} do
    with_device(e)
    stale = age_record(e.record_id)

    deliver(session([]), e)

    last_active_at = Records.get_record(e.record_id).last_active_at
    assert DateTime.compare(last_active_at, stale) == :gt
  end

  test "classification has a hard timeout", %{enrollment: e} do
    device = with_device(e)
    key = DKIMSigner.rsa_key()
    DKIMTestResolver.put("slow._domainkey.hsbc.bank.in", {:sleep, 5_000})
    data = DKIMSigner.sign(@otp_mail, key, d: "hsbc.bank.in", s: "slow")

    log =
      capture_log(fn ->
        {micros, _} = :timer.tc(fn -> deliver(session(classify_timeout_ms: 100), e, data) end)
        assert micros < 2_000_000
      end)

    assert log =~ "classification timed out"
    refute log =~ "482913"
    refute_enqueued(worker: PushWorker, args: %{"device_id" => device.id})
  end

  describe "SMTP_REQUIRE_TLS" do
    test "refuses MAIL before STARTTLS when TLS is configured" do
      state = session(tls?: true, require_tls?: true)

      assert {:error, "530 5.7.0 Must issue a STARTTLS command first", ^state} =
               Session.handle_MAIL("a@b.c", state)

      assert {:ok, _} =
               state |> Session.handle_STARTTLS() |> then(&Session.handle_MAIL("a@b.c", &1))
    end

    test "is ignored without a TLS certificate" do
      assert {:ok, _} = Session.handle_MAIL("a@b.c", session(tls?: false, require_tls?: true))
    end

    test "is off by default" do
      assert {:ok, _} = Session.handle_MAIL("a@b.c", session(tls?: true))
    end
  end
end
