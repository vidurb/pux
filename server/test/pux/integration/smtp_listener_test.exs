defmodule Pux.Integration.SmtpListenerTest do
  @moduledoc "Talks SMTP to the real listener started by the application (see config/test.exs)."
  use Pux.DataCase, async: false
  use Oban.Testing, repo: Pux.Repo

  alias Pux.{DKIMSigner, Fixtures, Records}
  alias Pux.Workers.PushWorker

  @port Application.compile_env!(:pux, [:smtp, :port])
  @client_opts [relay: "127.0.0.1", port: @port, tls: :never, auth: :never, hostname: "t.local"]

  setup do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())

    {:ok, device} =
      Records.register_device(enrollment.record_id, %{
        push_token: "fcm-token-smtp",
        platform: :fcm
      })

    {:ok, enrollment: enrollment, device: device}
  end

  defp send_mail(to, body, from \\ "hsbc@hsbc.bank.in") do
    :gen_smtp_client.send_blocking({from, [to], body}, @client_opts)
  end

  test "accepts an OTP email and enqueues a push", %{enrollment: e, device: device} do
    body = "From: hsbc@hsbc.bank.in\r\nSubject: OTP\r\n\r\nYour OTP is 482913\r\n"
    assert "250 OK\r\n" = send_mail(e.inbox_address, body)
    assert_enqueued(worker: PushWorker, args: %{"device_id" => device.id})
  end

  defp delivered_payload(device, public, secret) do
    [job] = all_enqueued(worker: PushWorker, args: %{"device_id" => device.id})
    {:ok, ciphertext} = Base.url_decode64(job.args["envelope"]["ciphertext"], padding: false)
    {:ok, plaintext} = :enacl.box_seal_open(ciphertext, public, secret)
    Jason.decode!(plaintext)
  end

  defp keyed_record do
    %{public: public, secret: secret} = :enacl.box_keypair()
    {:ok, e} = Records.create_record(public)

    {:ok, device} =
      Records.register_device(e.record_id, %{push_token: "fcm-dkim", platform: :fcm})

    {e, device, public, secret}
  end

  test "a Gmail-forwarded, DKIM-signed bank OTP arrives verified" do
    {e, device, public, secret} = keyed_record()
    key = DKIMSigner.rsa_key()
    selector = DKIMSigner.publish(key, "hsbc.bank.in")

    # Leading dots exercise SMTP dot-stuffing on the way through.
    bank =
      "From: HSBC <hsbc@hsbc.bank.in>\r\nSubject: OTP\r\n\r\n.Your OTP is 482913\r\n..\r\n\r\n"

    body =
      "X-Forwarded-To: #{e.inbox_address}\r\nX-Forwarded-For: someone@gmail.com\r\n" <>
        DKIMSigner.sign(bank, key, d: "hsbc.bank.in", s: selector)

    assert "250 OK\r\n" = send_mail(e.inbox_address, body, "someone@gmail.com")

    assert %{
             "type" => "otp",
             "otp" => "482913",
             "sender" => "HSBC",
             "sender_domain" => "hsbc.bank.in",
             "verified" => true
           } = delivered_payload(device, public, secret)
  end

  test "an unsigned bank OTP arrives unverified" do
    {e, device, public, secret} = keyed_record()
    body = "From: hsbc@hsbc.bank.in\r\nSubject: OTP\r\n\r\nYour OTP is 482913\r\n"
    assert "250 OK\r\n" = send_mail(e.inbox_address, body)

    assert %{"sender" => "hsbc.bank.in", "verified" => false} =
             delivered_payload(device, public, secret)
  end

  test "rejects the wrong domain", %{enrollment: e} do
    assert {:error, :send, {:permanent_failure, _, "550" <> _}} =
             send_mail("#{e.inbox_token}@other.example", "Subject: x\r\n\r\nOTP 123456\r\n")
  end

  test "a relay with no devices bounces exactly like an unknown inbox" do
    {:ok, deviceless} = Records.create_record(Fixtures.public_key())
    body = "Subject: x\r\n\r\nYour OTP is 123456\r\n"

    assert {:error, :send, {:permanent_failure, _, deviceless_reply}} =
             send_mail(deviceless.inbox_address, body)

    assert {:error, :send, {:permanent_failure, _, unknown_reply}} =
             send_mail("unknowninbox1234@pux.test", body)

    assert "550 5.1.1" <> _ = deviceless_reply
    assert deviceless_reply == unknown_reply
  end

  test "rejects an unknown inbox" do
    assert {:error, :send, {:permanent_failure, _, "550" <> _}} =
             send_mail("unknowninbox1234@pux.test", "Subject: x\r\n\r\nOTP 123456\r\n")
  end

  test "rejects an oversize message", %{enrollment: e} do
    body = "Subject: big\r\n\r\n" <> String.duplicate("a", 3000) <> "\r\n"
    assert {:error, _, {_, _, "552" <> _}} = send_mail(e.inbox_address, body)
    refute_enqueued(worker: PushWorker)
  end

  test "EHLO advertises SIZE and MAIL extensions are refused cleanly" do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, active: false, packet: :line])

    {:ok, "220 " <> _} = :gen_tcp.recv(socket, 0, 2000)
    :ok = :gen_tcp.send(socket, "EHLO t.local\r\n")
    assert read_multiline(socket) =~ "250-SIZE 2000"

    :ok = :gen_tcp.send(socket, "MAIL FROM:<x@y.z> RET=HDRS\r\n")
    assert {:ok, "555" <> _} = :gen_tcp.recv(socket, 0, 2000)

    :ok = :gen_tcp.send(socket, "VRFY root\r\n")
    assert {:ok, "252" <> _} = :gen_tcp.recv(socket, 0, 2000)
    :gen_tcp.close(socket)
  end

  defp read_multiline(socket, acc \\ "") do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2000)

    case line do
      <<_::binary-size(3), "-", _::binary>> -> read_multiline(socket, acc <> line)
      _ -> acc <> line
    end
  end
end
