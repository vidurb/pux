import Config

# TLS terminates at the gateway; trust its X-Forwarded-Proto. force_ssl is read at
# compile time, so it lives here rather than in runtime.exs.
config :pux, PuxWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  force_ssl: [
    hsts: true,
    rewrite_on: [:x_forwarded_proto],
    exclude: [hosts: ["localhost", "127.0.0.1"], paths: ["/health"]]
  ]

config :pux, :secure_cookies, true

config :logger, level: :info
