defmodule PuxWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :pux

  @session_options [
    store: :cookie,
    key: "_pux_key",
    signing_salt: "pux_cookie_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

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
  plug Plug.Session, @session_options
  plug PuxWeb.Router
end
