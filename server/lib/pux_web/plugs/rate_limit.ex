defmodule PuxWeb.Plugs.RateLimit do
  @moduledoc """
  IP-based rate limiting for record creation endpoints.
  """
  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, opts) do
    rate_config = Application.get_env(:pux, :rate_limit, [])
    key = Keyword.get(opts, :key, "default")
    scale_ms = Keyword.get(opts, :scale_ms, Keyword.get(rate_config, :record_create_scale_ms, 60_000))
    limit = Keyword.get(opts, :limit, Keyword.get(rate_config, :record_create_limit, 10))
    client_key = "#{key}:#{client_ip(conn)}"

    case Hammer.check_rate(client_key, scale_ms, limit) do
      {:allow, _count} ->
        conn

      {:deny, _retry_after} ->
        Logger.info("Rate limit exceeded for #{client_key}")

        conn
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{error: "rate_limit_exceeded"})
        |> halt()
    end
  end

  @spec allow?(String.t(), keyword()) :: :ok | {:error, :rate_limited}
  def allow?(client_key, opts \\ []) do
    key = Keyword.get(opts, :key, "default")
    scale_ms = Keyword.get(opts, :scale_ms, 60_000)
    limit = Keyword.get(opts, :limit, 10)
    full_key = "#{key}:#{client_key}"

    case Hammer.check_rate(full_key, scale_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, _retry_after} -> {:error, :rate_limited}
    end
  end

  defp client_ip(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> List.first()
    |> case do
      nil ->
        conn.remote_ip |> :inet.ntoa() |> to_string()

      forwarded ->
        forwarded |> String.split(",", parts: 2) |> List.first() |> String.trim()
    end
  end
end
