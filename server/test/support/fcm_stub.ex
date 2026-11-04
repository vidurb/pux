defmodule Pux.FCMStub do
  @moduledoc """
  A local stand-in for FCM, reached over real HTTP, so tests cover the whole path from job to
  request to classified response. Sends each request to the test process and answers with
  what the test chose for that token (200 by default).
  """
  @behaviour Plug

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  @unregistered ~s({"error":{"code":404,"status":"NOT_FOUND","details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"UNREGISTERED"}]}})

  def unregistered, do: {404, @unregistered}

  @doc "Turns FCM on for the test, pointed at a local server. `responses` maps token to reply."
  def start(responses \\ %{}) do
    server =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__, %{test: self(), responses: responses}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base_url = "http://127.0.0.1:#{port}"
    previous = Application.get_env(:pux, :fcm)
    on_exit(fn -> Application.put_env(:pux, :fcm, previous) end)

    Application.put_env(:pux, :fcm,
      enabled: true,
      project_id: "pux-test",
      base_url: base_url <> "/v1/projects"
    )

    credentials = %{"client_id" => "c", "client_secret" => "s", "refresh_token" => "r"}

    start_supervised!(
      {Goth, name: Pux.Goth, source: {:refresh_token, credentials, url: base_url <> "/token"}}
    )

    :ok
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/token"} = conn, _opts) do
    body = ~s({"access_token":"test","expires_in":3600,"token_type":"Bearer"})
    Plug.Conn.send_resp(conn, 200, body)
  end

  def call(conn, %{test: test, responses: responses}) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    send(test, {:fcm_request, request})

    {status, reply} = Map.get(responses, request["message"]["token"], {200, ~s({"name":"m"})})
    Plug.Conn.send_resp(conn, status, reply)
  end
end
