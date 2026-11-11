defmodule Pux.DKIMTest do
  use ExUnit.Case, async: true

  alias Pux.{DKIM, DKIMSigner, DKIMTestResolver}

  @rsa DKIMSigner.rsa_key()

  @message "From: HSBC <hsbc@hsbc.bank.in>\r\nTo: abc@pux.test\r\nSubject: OTP\r\nDate: Thu, 29 Oct 2026 10:00:00 +0530\r\n\r\nYour  OTP is 482913. \r\n\r\nDo not share.\r\n\r\n"

  defp signed(opts \\ [], message \\ @message, key \\ @rsa) do
    selector = DKIMSigner.publish(key, Keyword.get(opts, :d, "hsbc.bank.in"))
    DKIMSigner.sign(message, key, Keyword.merge([d: "hsbc.bank.in", s: selector], opts))
  end

  describe "RFC 8463 appendix A" do
    setup do
      DKIMTestResolver.put(
        "brisbane._domainkey.football.example.com",
        "v=DKIM1; k=ed25519; p=11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
      )

      DKIMTestResolver.put("test._domainkey.football.example.com", [
        "v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDkHlOQoBTzWR" <>
          "iGs5V6NpP3idY6Wk08a5qhdR6wy5bdOKb2jLQiY/J16JYi0Qvx/byYzCNb3W91y3FutAC" <>
          "DfzwQ/BC/e/8uBsCR+yz1Lxj+PL6lHvqMKrM3rG4hstT5QjvHO9PzoxZyVYLzBfO2EeC3" <>
          "Ip3G+2kryOTIKT+l/K4w3QIDAQAB"
      ])

      :ok
    end

    @ed25519_sig """
    DKIM-Signature: v=1; a=ed25519-sha256; c=relaxed/relaxed;
     d=football.example.com; i=@football.example.com;
     q=dns/txt; s=brisbane; t=1528637909; h=from : to :
     subject : date : message-id : from : subject : date;
     bh=2jUSOH9NhtVGCQWNr9BrIAPreKQjO6Sn7XIkfJVOzv8=;
     b=/gCrinpcQOoIfuHNQIbq4pgh9kyIK3AQUdt9OdqQehSwhEIug4D11Bus
     Fa3bT3FY5OsU7ZbnKELq+eXdp1Q1Dw==
    """

    @rsa_sig """
    DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed;
     d=football.example.com; i=@football.example.com;
     q=dns/txt; s=test; t=1528637909; h=from : to : subject :
     date : message-id : from : subject : date;
     bh=2jUSOH9NhtVGCQWNr9BrIAPreKQjO6Sn7XIkfJVOzv8=;
     b=F45dVWDfMbQDGHJFlXUNB2HKfbCeLRyhDXgFpEL8GwpsRe0IeIixNTe3
     DhCVlUrSjV4BwcVcOF6+FF3Zo9Rpo1tFOeS9mPYQTnGdaSGsgeefOsk2Jz
     dA+L10TeYt9BgDfQNZtKdN1WO//KgIqXP7OdEFE4LjFYNcUxZQ4FADY+8=
    """

    @rfc_message """
    From: Joe SixPack <joe@football.example.com>
    To: Suzie Q <suzie@shopping.example.net>
    Subject: Is dinner ready?
    Date: Fri, 11 Jul 2003 21:00:37 -0700 (PDT)
    Message-ID: <20030712040037.46341.5F8J@football.example.com>

    Hi.

    We lost the game.  Are you hungry yet?

    Joe.
    """

    defp crlf(text), do: String.replace(text, "\n", "\r\n")

    test "verifies the ed25519-sha256 example" do
      assert DKIM.aligned?(crlf(@ed25519_sig <> @rfc_message), "football.example.com")
    end

    test "verifies the rsa-sha256 example" do
      assert DKIM.aligned?(crlf(@rsa_sig <> @rfc_message), "football.example.com")
    end

    test "verifies the example as gen_smtp delivers it (final CRLF stripped)" do
      raw = crlf(@ed25519_sig <> @rsa_sig <> @rfc_message) |> String.replace_suffix("\r\n", "")
      assert DKIM.aligned?(raw, "football.example.com")
    end
  end

  test "valid rsa signature aligns with the From domain" do
    assert DKIM.aligned?(signed(), "hsbc.bank.in")
  end

  test "simple canonicalisation" do
    assert DKIM.aligned?(signed(c: {:simple, :simple}), "hsbc.bank.in")
    assert DKIM.aligned?(signed(c: {:relaxed, :simple}), "hsbc.bank.in")

    refute DKIM.aligned?(
             signed(c: {:simple, :simple}) |> String.replace("Your  OTP", "Your OTP"),
             "hsbc.bank.in"
           )
  end

  test "relaxed body tolerates whitespace changes" do
    raw = signed() |> String.replace("Your  OTP is 482913. ", "Your OTP is 482913.")
    assert DKIM.aligned?(raw, "hsbc.bank.in")
  end

  test "ed25519 signature" do
    assert DKIM.aligned?(signed([], @message, DKIMSigner.ed25519_key()), "hsbc.bank.in")
  end

  test "parent and subdomains align, unrelated domains don't" do
    assert DKIM.aligned?(signed(), "alerts.hsbc.bank.in")
    assert DKIM.aligned?(signed(d: "mail.hsbc.bank.in"), "hsbc.bank.in")
    refute DKIM.aligned?(signed(), "hsbc.bank.in.evil.example")
    refute DKIM.aligned?(signed(d: "evil.example"), "hsbc.bank.in")
  end

  test "tampered body fails" do
    raw = signed() |> String.replace("482913", "111111")
    refute DKIM.aligned?(raw, "hsbc.bank.in")
  end

  test "tampered signed header fails" do
    raw = signed() |> String.replace("Subject: OTP", "Subject: Your OTP")
    refute DKIM.aligned?(raw, "hsbc.bank.in")
  end

  test "unsigned header changes don't matter" do
    raw = signed() |> String.replace("To: abc@pux.test", "To: other@pux.test")
    assert DKIM.aligned?(raw, "hsbc.bank.in")
  end

  test "a second From header is never aligned" do
    raw = "From: evil@evil.example\r\n" <> signed()
    refute DKIM.aligned?(raw, "hsbc.bank.in")
  end

  test "missing or revoked key fails" do
    raw = DKIMSigner.sign(@message, @rsa, d: "hsbc.bank.in", s: "nokey")
    refute DKIM.aligned?(raw, "hsbc.bank.in")

    DKIMTestResolver.put("revoked._domainkey.hsbc.bank.in", "v=DKIM1; k=rsa; p=")
    raw = DKIMSigner.sign(@message, @rsa, d: "hsbc.bank.in", s: "revoked")
    refute DKIM.aligned?(raw, "hsbc.bank.in")
  end

  test "wrong key fails" do
    selector = DKIMSigner.publish(DKIMSigner.rsa_key(), "hsbc.bank.in")
    raw = DKIMSigner.sign(@message, @rsa, d: "hsbc.bank.in", s: selector)
    refute DKIM.aligned?(raw, "hsbc.bank.in")
  end

  test "x= expiry" do
    now = System.os_time(:second)
    assert DKIM.aligned?(signed(extra: ["x=#{now + 60}"]), "hsbc.bank.in")
    refute DKIM.aligned?(signed(extra: ["x=#{now - 60}"]), "hsbc.bank.in")
  end

  test "l= must cover the whole body" do
    [_, body] = :binary.split(@message, "\r\n\r\n")
    len = byte_size(DKIM.canon_body(body, :relaxed))

    assert DKIM.aligned?(signed(extra: ["l=#{len}"]), "hsbc.bank.in")
    refute DKIM.aligned?(signed(extra: ["l=10"]), "hsbc.bank.in")
  end

  test "signatures that don't sign From are ignored" do
    refute DKIM.aligned?(signed(h: ["subject", "date"]), "hsbc.bank.in")
  end

  test "dot-unstuffed lines and an empty trailing body verify" do
    message = "From: a@hsbc.bank.in\r\nSubject: x\r\n\r\n.leading dot\r\n..two\r\n"
    raw = signed([], message)
    assert DKIM.aligned?(raw, "hsbc.bank.in")
    assert DKIM.aligned?(String.replace_suffix(raw, "\r\n", ""), "hsbc.bank.in")
  end

  test "unsigned and garbage messages" do
    refute DKIM.aligned?(@message, "hsbc.bank.in")
    refute DKIM.aligned?("garbage", "hsbc.bank.in")
    refute DKIM.aligned?("DKIM-Signature: v=1; a=rsa-sha256\r\nFrom: a@b.c\r\n\r\nx", "b.c")
    refute DKIM.aligned?(signed(), nil)
  end
end
