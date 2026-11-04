defmodule PuxWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :pux

  # No LiveView socket: pages are served as static HTML without LiveView JS.

  # Served at /ws/delivery itself (Phoenix appends "/websocket" by default).
  socket "/ws/delivery", PuxWeb.DeliverySocket,
    websocket: [
      path: "",
      connect_info: [:peer_data, :x_headers],
      error_handler: {PuxWeb.DeliverySocket, :handle_error, []},
      timeout: 90_000
    ],
    longpoll: false

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
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: {__MODULE__, :log_level, []}

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug :put_content_security_policy
  plug :session
  plug PuxWeb.Router

  # Health probes would otherwise drown everything else.
  def log_level(%{path_info: ["health"]}), do: false
  def log_level(_conn), do: :info

  # The site is static HTML with one same-origin stylesheet. Set before the router so
  # put_secure_browser_headers keeps it instead of its permissive default.
  @content_security_policy "default-src 'none'; style-src 'self'; img-src 'self'; " <>
                             "base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

  def put_content_security_policy(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "content-security-policy", @content_security_policy)
  end

  def session(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(session_options()))
  end

  def session_options do
    [
      store: :cookie,
      key: "_pux_key",
      signing_salt: cookie_signing_salt(),
      same_site: "Lax",
      secure: Application.get_env(:pux, :secure_cookies, false)
    ]
  end

  defp cookie_signing_salt do
    Application.get_env(:pux, PuxWeb.Endpoint)[:cookie_signing_salt] || "pux_cookie_salt"
  end
end
