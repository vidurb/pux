defmodule PuxWeb.Plugs.RecordRateLimit do
  @moduledoc """
  Rate limits authenticated endpoints per record. Must run after `PuxWeb.Plugs.RecordAuth`.
  Options override `config :pux, :record_rate_limit`, or with `config: name`, the limit
  in `config :pux, name` instead. A limit of its own needs its own `:key`, so it counts
  separately.
  """
  import Plug.Conn

  alias PuxWeb.Plugs.RateLimit

  require Logger

  def init(opts), do: opts

  def call(%{assigns: %{record_id: record_id}} = conn, opts) do
    {config_name, opts} = Keyword.pop(opts, :config, :record_rate_limit)
    config = Keyword.merge(Application.get_env(:pux, config_name, []), opts)

    case RateLimit.allow?(record_id,
           key: Keyword.get(config, :key, "record_api"),
           limit: Keyword.get(config, :limit, 60),
           scale_ms: Keyword.get(config, :scale_ms, 60_000)
         ) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        Logger.info("Record API rate limit exceeded")

        conn
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{error: "rate_limit_exceeded"})
        |> halt()
    end
  end
end
