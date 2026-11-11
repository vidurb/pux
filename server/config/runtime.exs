import Config

if config_env() == :prod do
  # Empty values (e.g. `SMTP_TLS_CERTFILE=` in a Compose .env) count as unset.
  env = fn name -> if (value = System.get_env(name)) not in [nil, ""], do: value end

  database_url =
    env.("DATABASE_URL") ||
      raise "DATABASE_URL is required"

  maybe_ipv6 = if env.("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :pux, Pux.Repo,
    url: database_url,
    pool_size: String.to_integer(env.("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    env.("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is required"

  host = env.("PHX_HOST") || "pux.vidur.xyz"
  port = String.to_integer(env.("PORT") || "4000")

  live_view_signing_salt =
    env.("LIVE_VIEW_SIGNING_SALT") ||
      raise "LIVE_VIEW_SIGNING_SALT is required in production"

  cookie_signing_salt =
    env.("COOKIE_SIGNING_SALT") ||
      raise "COOKIE_SIGNING_SALT is required in production"

  config :pux, PuxWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    cookie_signing_salt: cookie_signing_salt,
    check_origin: ["https://#{host}"],
    live_view: [signing_salt: live_view_signing_salt]

  smtp_port = String.to_integer(env.("SMTP_PORT") || "2525")
  mail_domain = env.("MAIL_DOMAIN") || host
  smtp_max_message_size = String.to_integer(env.("SMTP_MAX_MESSAGE_SIZE") || "1048576")

  smtp_tls_certfile = env.("SMTP_TLS_CERTFILE")
  smtp_tls_keyfile = env.("SMTP_TLS_KEYFILE")

  config :pux, :smtp,
    port: smtp_port,
    domain: mail_domain,
    mail_domain: mail_domain,
    max_message_size: smtp_max_message_size,
    max_connections: String.to_integer(env.("SMTP_MAX_CONNECTIONS") || "100"),
    # 0 turns the per-IP limit off (behind a TCP proxy every connection has the proxy's IP);
    # empty counts as unset, like everywhere else, so it gives the default.
    max_connections_per_ip: String.to_integer(env.("SMTP_MAX_CONNECTIONS_PER_IP") || "5"),
    tls_certfile: smtp_tls_certfile,
    tls_keyfile: smtp_tls_keyfile,
    require_tls: env.("SMTP_REQUIRE_TLS") in ~w(true 1),
    inbound_rate_limit: String.to_integer(env.("SMTP_INBOUND_RATE_LIMIT") || "20"),
    inbound_rate_scale_ms: String.to_integer(env.("SMTP_INBOUND_RATE_SCALE_MS") || "600000")

  unless smtp_tls_certfile && smtp_tls_keyfile do
    IO.warn(
      "SMTP_TLS_CERTFILE/SMTP_TLS_KEYFILE not set; inbound SMTP is plaintext only" <>
        if(env.("SMTP_REQUIRE_TLS") in ~w(true 1),
          do: " and SMTP_REQUIRE_TLS has no effect",
          else: ""
        )
    )
  end

  config :pux, :records, max_devices: String.to_integer(env.("MAX_DEVICES_PER_RECORD") || "10")

  config :pux, :record_rate_limit,
    limit: String.to_integer(env.("RECORD_API_RATE_LIMIT") || "120"),
    scale_ms: 60_000

  config :pux, :auth_failure_rate_limit,
    limit: String.to_integer(env.("AUTH_FAILURE_RATE_LIMIT") || "300"),
    scale_ms: 60_000

  if fcm_json = env.("FCM_SERVICE_ACCOUNT_JSON") do
    case Jason.decode(fcm_json) do
      {:ok, %{"project_id" => project_id}} when is_binary(project_id) ->
        config :pux, :fcm,
          enabled: true,
          project_id: project_id,
          service_account_json: fcm_json

      {:ok, _} ->
        IO.warn("FCM_SERVICE_ACCOUNT_JSON is missing project_id; FCM disabled")

      # The decode error holds the whole input, including the private key.
      {:error, %Jason.DecodeError{position: position}} ->
        IO.warn("FCM_SERVICE_ACCOUNT_JSON is invalid at byte #{position}; FCM disabled")
    end
  end

  if env.("PHX_SERVER") do
    config :pux, PuxWeb.Endpoint, server: true
  end
end
