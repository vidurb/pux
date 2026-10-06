defmodule Pux.SMTP.SessionTest do
  use Pux.DataCase, async: true

  alias Pux.{Fixtures, Records}
  alias Pux.SMTP.Session

  setup do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    {:ok, _banner, state} = Session.init("pux.test", 0, {127, 0, 0, 1}, mail_domain: "pux.test")
    {:ok, state} = Session.handle_MAIL("sender@bank.com", state)
    {:ok, state: state, enrollment: enrollment}
  end

  test "accepts a known inbox on the configured mail domain", %{state: state, enrollment: e} do
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
end
