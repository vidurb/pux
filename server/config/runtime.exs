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

  config :pux, PuxWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  smtp_port = String.to_integer(System.get_env("SMTP_PORT") || "25")
  mail_domain = System.get_env("MAIL_DOMAIN") || host

  config :pux, :smtp,
    port: smtp_port,
    domain: mail_domain,
    mail_domain: mail_domain

  if fcm_json = System.get_env("FCM_SERVICE_ACCOUNT_JSON") do
    config :pux, :fcm,
      enabled: true,
      project_id: Jason.decode!(fcm_json)["project_id"],
      service_account_json: fcm_json
  end
end
