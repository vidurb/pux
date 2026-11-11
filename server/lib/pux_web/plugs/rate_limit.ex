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
    client_key = "#{key}:#{rate_limit_key(conn)}"

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
  Key to rate limit the client of `conn` on: `client_ip/1`, with IPv6 addresses cut to
  their /64 (see `address_key/1`).
  """
  @spec rate_limit_key(Plug.Conn.t()) :: String.t()
  def rate_limit_key(conn), do: conn |> client_ip() |> address_key()

  @doc "The same, for callers with no conn. Takes the arguments of `client_ip/2`."
  @spec rate_limit_key(:inet.ip_address(), [String.t()]) :: String.t()
  def rate_limit_key(peer_address, forwarded_for_headers) do
    peer_address |> client_ip(forwarded_for_headers) |> address_key()
  end

  @doc """
  Rate limit key for one address, as a tuple or a string. IPv4 addresses, including
  IPv4-mapped IPv6, are kept whole. IPv6 addresses become their /64, such as
  `"2001:db8:1:2::/64"`, because a single client usually controls a whole /64 and could
  otherwise get a new limit for every address in it. A string that isn't an IP address
  is returned unchanged.
  """
  @spec address_key(:inet.ip_address() | String.t()) :: String.t()
  def address_key(address) when is_binary(address) do
    # Not String.to_charlist/1: a header value needn't be valid UTF-8.
    case :inet.parse_strict_address(:binary.bin_to_list(address)) do
      {:ok, ip} -> address_key(ip)
      {:error, _} -> address
    end
  end

  def address_key(address) when is_tuple(address) do
    case normalize_ip(address) do
      {a, b, c, d, _, _, _, _} -> "#{:inet.ntoa({a, b, c, d, 0, 0, 0, 0})}/64"
      ip -> ip |> :inet.ntoa() |> to_string()
    end
  end

  @doc """
  Client IP. Only the rightmost `X-Forwarded-For` hop (appended by the gateway) is
  trusted, and only when the peer is a private address. Rate limits key on
  `rate_limit_key/1` instead.
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
