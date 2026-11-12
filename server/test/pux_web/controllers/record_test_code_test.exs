defmodule PuxWeb.RecordTestCodeTest do
  use PuxWeb.ConnCase, async: true
  use Oban.Testing, repo: Pux.Repo

  alias Pux.{Deliveries, Fixtures, Push, Records}
  alias Pux.Workers.PushWorker

  setup do
    %{public: public, secret: secret} = :enacl.box_keypair()
    {:ok, enrollment} = Records.create_record(public)
    {:ok, record_id: enrollment.record_id, public: public, secret: secret}
  end

  defp send_test(conn, record_id) do
    conn
    |> put_req_header("authorization", "Bearer #{record_id}")
    |> post("/api/v1/record/test")
  end

  defp open(envelope, public, secret) do
    {:ok, ciphertext} = Base.url_decode64(envelope["ciphertext"], padding: false)
    {:ok, plaintext} = :enacl.box_seal_open(ciphertext, public, secret)
    Jason.decode!(plaintext)
  end

  test "sends a sealed test OTP to phones and desktops alike", ctx do
    %{record_id: id, public: public, secret: secret} = ctx
    {:ok, phone} = Records.register_device(id, %{push_token: "fcm-test-1", platform: :fcm})
    {:ok, _} = Records.register_device(id, %{push_token: "desktop-test-1", platform: :desktop})
    Phoenix.PubSub.subscribe(Pux.PubSub, Push.delivery_topic(id))

    conn = send_test(ctx.conn, id)

    assert %{"otp" => otp, "devices" => 2} = json_response(conn, 202)
    assert otp =~ ~r/^[1-9]\d{5}$/

    [job] = all_enqueued(worker: PushWorker, args: %{"device_id" => phone.id})

    # An ordinary OTP payload, so every app version shows it.
    assert %{
             "type" => "otp",
             "otp" => ^otp,
             "sender" => "pux test",
             "verified" => true
           } = open(job.args["envelope"], public, secret)

    assert [pending] = Deliveries.list_pending(id)
    assert open(pending.envelope, public, secret)["otp"] == otp
    assert_receive {:envelope, delivery_id, envelope}
    assert delivery_id == pending.id
    assert open(envelope, public, secret)["otp"] == otp
  end

  test "refuses a relay with no devices", %{conn: conn, record_id: id} do
    conn = send_test(conn, id)

    assert json_response(conn, 409) == %{"error" => "no_devices"}
    refute_enqueued(worker: PushWorker)
    assert Deliveries.list_pending(id) == []
  end

  test "allows only a few test codes per relay a minute", %{conn: conn, record_id: id} do
    {:ok, _} = Records.register_device(id, %{push_token: "fcm-test-2", platform: :fcm})
    limit = Application.fetch_env!(:pux, :test_code_rate_limit)[:limit]

    for _ <- 1..limit, do: assert(json_response(send_test(conn, id), 202))

    assert json_response(send_test(conn, id), 429) == %{"error" => "rate_limit_exceeded"}
    assert length(all_enqueued(worker: PushWorker)) == limit

    # The relay's other endpoints only have the general limit.
    deliveries =
      conn
      |> put_req_header("authorization", "Bearer #{id}")
      |> get("/api/v1/record/deliveries")

    assert json_response(deliveries, 200)

    # And another relay has a limit of its own.
    {:ok, other} = Records.create_record(Fixtures.public_key())

    {:ok, _} =
      Records.register_device(other.record_id, %{push_token: "fcm-test-3", platform: :fcm})

    assert json_response(send_test(conn, other.record_id), 202)
  end

  test "needs the relay's ID as the bearer token", %{conn: conn} do
    assert json_response(post(conn, "/api/v1/record/test"), 401) == %{"error" => "unauthorized"}

    unknown = send_test(conn, Ecto.UUID.generate())
    assert json_response(unknown, 401) == %{"error" => "unauthorized"}
  end
end
