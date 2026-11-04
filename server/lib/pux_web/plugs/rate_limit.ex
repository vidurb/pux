defmodule PuxWeb.Plugs.RateLimit do
  @moduledoc """
  IP-based rate limiting for record creation endpoints, plus the shared helpers the other
  limits use.
  """
  import Plug.Conn

  require Logger

  defmodule Limiter do
    @moduledoc false
    use Hammer, backend: :ets
  end

  def init(opts), do: opts

  def call(conn, opts) do
    rate_config = Application.get_env(:pux, :rate_limit, [])
    key = Keyword.get(opts, :key, "default")

    scale_ms =
      Keyword.get(opts, :scale_ms, Keyword.get(rate_config, :record_create_scale_ms, 60_000))

    limit = Keyword.get(opts, :limit, Keyword.get(rate_config, :record_create_limit, 10))
    client_key = "#{key}:#{client_ip(conn)}"

    case Limiter.hit(client_key, scale_ms, limit) do
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

    case Limiter.hit(full_key, scale_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, _retry_after} -> {:error, :rate_limited}
    end
  end

  @doc """
  Whether `client_key` has used up its limit, without counting this check against it as
  `allow?/2` would. Takes the same options as `allow?/2`.
  """
  @spec limit_reached?(String.t(), keyword()) :: boolean()
  def limit_reached?(client_key, opts \\ []) do
    key = Keyword.get(opts, :key, "default")
    scale_ms = Keyword.get(opts, :scale_ms, 60_000)
    limit = Keyword.get(opts, :limit, 10)

    Limiter.get("#{key}:#{client_key}", scale_ms) >= limit
  end

  @doc """
  Client IP for rate limiting. Only the rightmost `X-Forwarded-For` hop (appended
  by the gateway) is trusted, and only when the peer is a private address.
  """
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    client_ip(conn.remote_ip, get_req_header(conn, "x-forwarded-for"))
  end

  @doc """
  The same, for callers with no conn: a peer address and the `X-Forwarded-For` header
  values, such as a WebSocket's `connect_info`.
  """
  @spec client_ip(:inet.ip_address(), [String.t()]) :: String.t()
  def client_ip(peer_address, forwarded_for_headers) do
    peer = normalize_ip(peer_address)

    case {private_ip?(peer), forwarded_for(forwarded_for_headers)} do
      {true, [_ | _] = hops} -> List.last(hops)
      _ -> peer |> :inet.ntoa() |> to_string()
    end
  end

  defp forwarded_for(headers) do
    headers
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_ip({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    import Bitwise
    {ab >>> 8, ab &&& 0xFF, cd >>> 8, cd &&& 0xFF}
  end

  defp normalize_ip(ip), do: ip

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({100, b, _, _}) when b in 64..127, do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp private_ip?(_), do: false
end
