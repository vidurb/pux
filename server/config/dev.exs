import Config

config :pux, Pux.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "pux_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :pux, PuxWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_replace_in_prod_at_least_64_bytes_long_xxxxxxxx",
  watchers: []

config :pux, dev_routes: true
config :logger, level: :debug
config :phoenix, :stacktrace_depth, 20

config :pux, :fcm,
  enabled: false,
  project_id: nil
