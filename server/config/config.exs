import Config

config :pux,
  ecto_repos: [Pux.Repo],
  generators: [binary_id: true]

config :pux, Pux.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id]

config :pux, PuxWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  cookie_signing_salt: "pux_cookie_salt_dev",
  render_errors: [
    formats: [html: PuxWeb.ErrorHTML, json: PuxWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Pux.PubSub,
  live_view: [signing_salt: "pux_signing_salt"]

config :pux, :smtp,
  port: 2525,
  domain: "localhost",
  mail_domain: "localhost",
  max_message_size: 1_048_576

config :pux, :rate_limit,
  record_create_scale_ms: 60_000,
  record_create_limit: 10

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 4]}

config :pux, :pruner,
  record_ttl_days: 90,
  device_ttl_days: 30

config :pux, Oban,
  repo: Pux.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", Pux.Workers.PruneWorker}
     ]}
  ],
  queues: [default: 10, push: 20]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
