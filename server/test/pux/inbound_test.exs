defmodule Pux.InboundTest do
  use ExUnit.Case, async: true

  alias Pux.{DKIMSigner, Inbound}

  import ExUnit.CaptureLog

  @rsa DKIMSigner.rsa_key()

  @bank "From: HSBC <hsbc@hsbc.bank.in>\r\nSubject: OTP\r\nDate: Thu, 29 Oct 2026 10:00:00 +0530\r\n\r\nYour OTP is 482913\r\n"

  @gmail_confirm """
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

  defp sign(raw, domain) do
    DKIMSigner.sign(raw, @rsa, d: domain, s: DKIMSigner.publish(@rsa, domain))
  end

  test "labels a DKIM-verified bank OTP" do
    assert {:ok, payload} = Inbound.classify(sign(@bank, "hsbc.bank.in"))

    assert %{
             type: "otp",
             otp: "482913",
             sender: "HSBC",
             sender_domain: "hsbc.bank.in",
             verified: true,
             parser: :hsbc
           } = payload
  end

  test "an unsigned bank OTP is delivered unverified, labelled by domain" do
    assert {:ok, payload} = Inbound.classify(@bank)

    assert %{
             otp: "482913",
             sender: "hsbc.bank.in",
             sender_domain: "hsbc.bank.in",
             verified: false,
             parser: :generic
           } = payload
  end

  test "a signature from another domain doesn't verify the From domain" do
    assert {:ok, %{sender: "hsbc.bank.in", verified: false}} =
             Inbound.classify(sign(@bank, "evil.example"))
  end

  test "a tampered signed message is unverified" do
    raw = @bank |> sign("hsbc.bank.in") |> String.replace("482913", "111111")

    assert {:ok, %{otp: "111111", verified: false, sender: "hsbc.bank.in"}} =
             Inbound.classify(raw)
  end

  test "Gmail auto-forwarded bank mail keeps the bank signature" do
    forwarded =
      "Received: by 2002:a05:6000:1:b0:1 with SMTP id x; Thu, 29 Oct 2026 04:30:01 -0700\r\n" <>
        "X-Forwarded-To: abc@pux.test\r\nX-Forwarded-For: someone@gmail.com abc@pux.test\r\n" <>
        "Delivered-To: someone@gmail.com\r\n" <>
        "ARC-Seal: i=1; a=rsa-sha256; t=1; cv=none; d=google.com; s=arc-20240605; b=AAAA\r\n" <>
        sign(@bank, "hsbc.bank.in")

    assert {:ok, %{sender: "HSBC", verified: true}} = Inbound.classify(forwarded)
  end

  test "no From header gives an unknown, unverified sender" do
    assert {:ok, %{sender: "Unknown sender", sender_domain: nil, verified: false}} =
             Inbound.classify("Subject: OTP\r\n\r\nYour OTP is 482913\r\n")
  end

  test "builds a forward_confirm payload for google.com-signed Gmail confirmations" do
    assert {:ok, payload} = Inbound.classify(sign(@gmail_confirm, "google.com"))
    assert payload.type == "forward_confirm"
    assert payload.code == "816235124"
    assert payload.url == "https://mail-settings.google.com/mail/vf-%5BANGjdJ8%5D-abc"
    assert payload.forwarding_from == "someone@gmail.com"
    assert payload.sender == "Gmail"
  end

  test "ignores spoofed Gmail forwarding confirmations" do
    assert :ignore = Inbound.classify(@gmail_confirm)
    assert :ignore = Inbound.classify(sign(@gmail_confirm, "evil.example"))

    assert :ignore =
             Inbound.classify(
               "Subject: x\r\n\r\nConfirmation code: 816235124\r\n",
               "forwarding-noreply@google.com"
             )
  end

  test "ignores mail without an OTP" do
    assert :ignore = Inbound.classify("Subject: hi\r\n\r\nNothing to see.\r\n")
  end

  test "reads HTML-only messages" do
    raw =
      "From: alerts@rbl.bank.in\r\nSubject: OTP\r\nContent-Type: text/html\r\n\r\n<p>Your OTP is <b>918273</b></p>\r\n"

    assert {:ok, %{otp: "918273"}} = Inbound.classify(raw)
  end

  test "classifies a 1 MB body quickly" do
    raw = "From: a@example.com\r\nSubject: x\r\n\r\n" <> String.duplicate("OTP 12345 ", 100_000)
    {micros, result} = :timer.tc(fn -> Inbound.classify(raw) end)
    assert {:ok, %{otp: "12345"}} = result
    assert micros < 1_000_000
  end

  test "MIME parse failures don't log message content" do
    raw = "Date: secret garbage\r\n\r\nOTP 482913\r\n"

    log = capture_log(fn -> assert {:ok, %{otp: "482913"}} = Inbound.classify(raw) end)
    assert log =~ "failed to parse email (FunctionClauseError)"
    refute log =~ "secret"
  end
end
