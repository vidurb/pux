defmodule Pux.InboundTest do
  use ExUnit.Case, async: true

  alias Pux.Inbound

  test "builds an otp payload" do
    raw = "From: alerts@hdfcbank.net\r\nSubject: OTP\r\n\r\nYour OTP is 482913\r\n"

    assert {:ok, %{type: "otp", otp: "482913", sender: "HDFC Bank", parser: :hdfc}} =
             Inbound.classify(raw)
  end

  test "builds a forward_confirm payload for Gmail forwarding confirmations" do
    raw = """
    From: Gmail Team <forwarding-noreply@google.com>\r
    Subject: (#816235124) Gmail Forwarding Confirmation - Receive Mail from someone@gmail.com\r
    \r
    someone@gmail.com has requested to automatically forward mail to your email\r
    address abc@pux.test.\r
    Confirmation code: 816235124\r
    \r
    To allow someone@gmail.com to automatically forward mail to your address,\r
    please click the link below to confirm the request:\r
    \r
    https://mail-settings.google.com/mail/vf-%5BANGjdJ8%5D-abc\r
    """

    assert {:ok, payload} = Inbound.classify(raw)
    assert payload.type == "forward_confirm"
    assert payload.code == "816235124"
    assert payload.url == "https://mail-settings.google.com/mail/vf-%5BANGjdJ8%5D-abc"
    assert payload.forwarding_from == "someone@gmail.com"
    assert payload.sender == "Gmail"
  end

  test "ignores mail without an OTP" do
    assert :ignore = Inbound.classify("Subject: hi\r\n\r\nNothing to see.\r\n")
  end

  test "reads HTML-only messages" do
    raw =
      "From: alerts@kotak.com\r\nSubject: OTP\r\nContent-Type: text/html\r\n\r\n<p>Your OTP is <b>918273</b></p>\r\n"

    assert {:ok, %{otp: "918273"}} = Inbound.classify(raw)
  end
end
