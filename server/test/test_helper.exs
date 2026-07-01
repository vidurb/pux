ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Pux.Repo, :manual)

# Oban testing helpers
Application.put_env(:pux, Oban, testing: :manual)
