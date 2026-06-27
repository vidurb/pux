import Config

config :pux, Pux.Repo, pool: Ecto.Adapters.SQL.Sandbox
config :pux, PuxWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4002]
config :pux, :fcm, enabled: false
config :logger, level: :warning
