defmodule Pux.Repo do
  use Ecto.Repo,
    otp_app: :pux,
    adapter: Ecto.Adapters.Postgres
end
