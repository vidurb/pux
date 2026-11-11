defmodule PuxWeb.Plugs.RecordAuth do
  @moduledoc """
  Identifies the relay from the bearer token, which is its record ID.

  A missing or malformed token and the ID of a record that doesn't exist all get the same
  401, so a response never says whether a record exists. The only timing difference is
  that a malformed token skips the lookup, which says nothing about any record.

  ## Failed authentication limit

  Each lookup that finds nothing counts against the client IP (its /64 for IPv6; see
  `PuxWeb.Plugs.RateLimit.rate_limit_key/1`). The limit is checked before
  the lookup, because the point is to save the query, so an IP over the limit gets 429 for
  a valid token too. That also keeps the 429 from saying whether a record exists. Requests
  that authenticate don't count, and neither do malformed tokens, which cost no query.

  Options, here and on `authenticate/3`, override `config :pux, :auth_failure_rate_limit`.
  """
  import Plug.Conn

  alias Pux.Records
  alias Pux.Records.Record
  alias PuxWeb.Plugs.RateLimit

  require Logger

  def init(opts), do: opts

  def call(conn, opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         # The stored ID, not the token: a UUID in another case finds the same record, and
         # must not get its own rate limit bucket.
         {:ok, record_id} <- authenticate(token, RateLimit.rate_limit_key(conn), opts) do
      assign(conn, :record_id, record_id)
    else
      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{error: "rate_limit_exceeded"})
        |> halt()

      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end

  @doc """
  Finds the record a token belongs to and returns its stored ID, applying the failed
  authentication limit for `client_key`, from `PuxWeb.Plugs.RateLimit.rate_limit_key/1`.
  """
  @spec authenticate(String.t(), String.t(), keyword()) ::
          {:ok, Ecto.UUID.t()} | {:error, :unauthorized | :rate_limited}
  def authenticate(token, client_key, opts \\ []) do
    limit =
      :pux
      |> Application.fetch_env!(:auth_failure_rate_limit)
      |> Keyword.put_new(:key, "auth_failure")
      |> Keyword.merge(opts)

    cond do
      not valid_uuid?(token) ->
        {:error, :unauthorized}

      RateLimit.limit_reached?(client_key, limit) ->
        # Neither the token nor the IP: the privacy policy says when an IP reaches the logs.
        Logger.info("Failed authentication rate limit exceeded")
        {:error, :rate_limited}

      true ->
        lookup(token, client_key, limit)
    end
  end

  defp lookup(token, client_key, limit) do
    case Records.get_record(token) do
      %Record{id: record_id} ->
        {:ok, record_id}

      nil ->
        # Only counting. This request has had its query, and the next one is checked anyway.
        _ = RateLimit.allow?(client_key, limit)
        {:error, :unauthorized}
    end
  end

  defp valid_uuid?(value) do
    match?(
      <<_::128>>,
      case Ecto.UUID.dump(value) do
        {:ok, bin} -> bin
        :error -> <<>>
      end
    )
  end
end
