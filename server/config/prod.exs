import Config

# TLS terminates at the gateway; trust its X-Forwarded-Proto. force_ssl is read at
# compile time, so it lives here rather than in runtime.exs.
config :pux, PuxWeb.Endpoint,
  force_ssl: [
    hsts: true,
    rewrite_on: [:x_forwarded_proto],
    exclude: [hosts: ["localhost", "127.0.0.1"], paths: ["/health"]],
    # The redirect log line repeats whatever URL a client asked for, and nothing needs it.
    log: false
  ]

config :pux, :secure_cookies, true

# Not :debug: Ecto logs query parameters and gen_smtp logs recipient addresses at that level,
# which would write record IDs and inbox tokens to the logs.
config :logger, level: :info
