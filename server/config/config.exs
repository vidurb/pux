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
  max_message_size: 1_048_576,
  require_tls: false,
  classify_timeout_ms: 5_000,
  inbound_rate_limit: 20,
  inbound_rate_scale_ms: 600_000

config :pux, :dkim, resolver: Pux.DKIMResolver

config :pux, :rate_limit,
  record_create_scale_ms: 60_000,
  record_create_limit: 10

# Per-record limit on authenticated API calls. Clients register on start and on resume
# (every 12 h) and desktops poll + ack on reconnect, so this is far above normal use.
config :pux, :record_rate_limit,
  limit: 120,
  scale_ms: 60_000

config :pux, :records, max_devices: 10

# Retention. See "Data retention" in README.md, and keep any published copy in step.
# - An FCM device stays until FCM reports its token dead: an app that is installed but rarely
#   opened is the normal case. `fcm_token_check_days` is how long a token can stay quiet
#   before a dry-run send asks FCM about it, which delivers nothing and removes only on
#   FCM's say-so.
# - `device_max_idle_days` is the hard limit for every device, because FCM can't report some
#   dead tokens (an uninstalled iOS app on a relay with no mail). Only a registration or an
#   accepted push restarts it, not a dry-run check.
# - Desktop devices have no such signal, so they age out. A running app re-registers every
#   12 h, and one that has been switched off re-registers when it starts.
# - A record lasts as long as it has a device, then `deviceless_record_ttl_days` more.
config :pux, :pruner,
  device_max_idle_days: 730,
  desktop_device_ttl_days: 90,
  deviceless_record_ttl_days: 30,
  fcm_token_check_days: 30,
  delivery_ttl_minutes: 10

config :pux, Oban,
  repo: Pux.Repo,
  plugins: [
    # Job args hold encrypted envelopes; don't keep finished jobs around.
    {Oban.Plugins.Pruner, max_age: 600},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(5)},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", Pux.Workers.PruneWorker},
       {"*/5 * * * *", Pux.Workers.PruneWorker, args: %{"scope" => "deliveries"}}
     ]}
  ],
  queues: [default: 10, push: 20]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "token", "push_token", "public_key", "id"]

import_config "#{config_env()}.exs"
