defmodule PuxWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :pux

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, session: {__MODULE__, :user_session, []}]],
    longpoll: [connect_info: [:peer_data, session: {__MODULE__, :user_session, []}]]

  socket "/ws/delivery", PuxWeb.DeliverySocket, websocket: true

  plug Plug.Static,
    at: "/",
    from: :pux,
    gzip: false,
    only: PuxWeb.static_paths()

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :pux
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  plug Plug.MethodOverride
  plug Plug.Head
  plug :session
  plug PuxWeb.Router

  def user_session(_conn), do: session_options()

  def session(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(session_options()))
  end

  def session_options do
    [
      store: :cookie,
      key: "_pux_key",
      signing_salt: cookie_signing_salt(),
      same_site: "Lax"
    ]
  end

  defp cookie_signing_salt do
    Application.get_env(:pux, PuxWeb.Endpoint)[:cookie_signing_salt] || "pux_cookie_salt"
  end
end
