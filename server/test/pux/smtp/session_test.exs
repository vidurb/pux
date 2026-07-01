defmodule Pux.SMTP.SessionTest do
  use ExUnit.Case, async: true

  alias Pux.SMTP.Session

  test "accepts recipient on configured mail domain" do
    {:ok, _banner, state} = Session.init("host", 1, {127, 0, 0, 1}, mail_domain: "pux.example")
    {:ok, state} = Session.handle_MAIL("sender@bank.com", state)

    assert {:ok, %{recipients: ["abc12345"]}} =
             Session.handle_RCPT("abc12345@pux.example", state)
  end

  test "rejects recipient on wrong mail domain" do
    {:ok, _banner, state} = Session.init("host", 1, {127, 0, 0, 1}, mail_domain: "pux.example")
    {:ok, state} = Session.handle_MAIL("sender@bank.com", state)

    assert {:error, "550 Recipient rejected", ^state} =
             Session.handle_RCPT("abc12345@wrong.example", state)
  end
end
