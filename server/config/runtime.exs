import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is required"

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :pux, Pux.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is required"

  host = System.get_env("PHX_HOST") || "pux.vidur.xyz"
  port = String.to_integer(System.get_env("PORT") || "4000")

  live_view_signing_salt =
    System.get_env("LIVE_VIEW_SIGNING_SALT") ||
      raise "LIVE_VIEW_SIGNING_SALT is required in production"

  cookie_signing_salt =
    System.get_env("COOKIE_SIGNING_SALT") ||
      raise "COOKIE_SIGNING_SALT is required in production"

  config :pux, PuxWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    cookie_signing_salt: cookie_signing_salt,
    check_origin: ["https://#{host}"],
    force_ssl: [hsts: true],
    live_view: [signing_salt: live_view_signing_salt]

  smtp_port = String.to_integer(System.get_env("SMTP_PORT") || "25")
  mail_domain = System.get_env("MAIL_DOMAIN") || host
  smtp_max_message_size = String.to_integer(System.get_env("SMTP_MAX_MESSAGE_SIZE") || "1048576")

  smtp_tls_certfile = System.get_env("SMTP_TLS_CERTFILE")
  smtp_tls_keyfile = System.get_env("SMTP_TLS_KEYFILE")

  config :pux, :smtp,
    port: smtp_port,
    domain: mail_domain,
    mail_domain: mail_domain,
    max_message_size: smtp_max_message_size,
    tls_certfile: smtp_tls_certfile,
    tls_keyfile: smtp_tls_keyfile

  if fcm_json = System.get_env("FCM_SERVICE_ACCOUNT_JSON") do
    case Jason.decode(fcm_json) do
      {:ok, %{"project_id" => project_id}} when is_binary(project_id) ->
        config :pux, :fcm,
          enabled: true,
          project_id: project_id,
          service_account_json: fcm_json

      {:ok, _} ->
        IO.warn("FCM_SERVICE_ACCOUNT_JSON is missing project_id; FCM disabled")

      {:error, reason} ->
        IO.warn("FCM_SERVICE_ACCOUNT_JSON is invalid (#{inspect(reason)}); FCM disabled")
    end
  end
end
