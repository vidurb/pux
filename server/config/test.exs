import Config

config :pux, Pux.Repo,
  url: System.get_env("DATABASE_URL") || "postgres://postgres:postgres@localhost/pux_test",
  pool: Ecto.Adapters.SQL.Sandbox

# server: true so tests can open real WebSocket connections.
config :pux, PuxWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: String.to_integer(System.get_env("PUX_TEST_HTTP_PORT", "4002"))
  ],
  server: true,
  secret_key_base: String.duplicate("t", 64)

config :pux, :smtp,
  port: String.to_integer(System.get_env("PUX_TEST_SMTP_PORT", "2526")),
  domain: "pux.test",
  mail_domain: "pux.test",
  max_message_size: 2000,
  max_connections_per_ip: 50

config :pux, :record_rate_limit, limit: 1_000_000

config :pux, :dkim, resolver: Pux.DKIMTestResolver

config :pux, :fcm, enabled: false
config :pux, Oban, testing: :manual
config :logger, level: :warning
