defmodule Pux.Integration.SmtpPushTest do
  use Pux.DataCase, async: false

  alias Pux.{Crypto, Fixtures, OtpParser, Push, Records}

  import ExUnit.CaptureLog

  test "end-to-end: record creation, OTP parse, encrypt payload" do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    record = Records.get_record(enrollment.record_id)

    body = "Dear customer, OTP is 654321 for your transaction."
    assert {:ok, parsed} = OtpParser.parse(body, from: "alerts@hdfcbank.net")

    plaintext =
      Jason.encode!(%{
        otp: parsed.otp,
        sender: parsed.sender_label,
        received_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    assert {:ok, ciphertext} = Crypto.seal(plaintext, record.public_key)
    assert is_binary(ciphertext)
    assert byte_size(ciphertext) > byte_size(plaintext)

    log =
      capture_log(fn ->
        assert :ok = Push.deliver_to_record(record, plaintext)
        Oban.drain_queue(queue: :push)
      end)

    assert log =~ "FCM disabled" or log == ""
  end

  test "pruner removes stale records" do
    {:ok, enrollment} = Records.create_record(Fixtures.public_key())
    record = Records.get_record(enrollment.record_id)

    stale_time = DateTime.utc_now() |> DateTime.add(-120, :day)

    record
    |> Ecto.Changeset.change(last_active_at: stale_time)
    |> Pux.Repo.update!()

    assert Records.prune_stale_records(90) >= 1
    assert Records.get_record(enrollment.record_id) == nil
  end
end
