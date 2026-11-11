defmodule PuxWeb.DeliverySocket do
  @moduledoc """
  WebSocket transport for desktop clients to receive encrypted OTP envelopes.
  """
  @behaviour Phoenix.Socket.Transport

  alias Pux.Push
  alias PuxWeb.Plugs.{RateLimit, RecordAuth}

  @impl true
  def child_spec(_opts) do
    # No child processes needed.
    :ignore
  end

  # The record ID is sent in the `x-pux-token` header only; query params end up in
  # proxy access logs.
  @impl true
  def connect(transport) do
    with token when is_binary(token) <- header_token(transport),
         # The stored ID, not the token: topics are matched exactly, so a UUID in another
         # case would subscribe to a topic nothing is ever sent to.
         {:ok, record_id} <- RecordAuth.authenticate(token, rate_limit_key(transport)) do
      {:ok, %{record_id: record_id}}
    else
      {:error, :rate_limited} -> {:error, :rate_limited}
      _ -> :error
    end
  end

  @doc "Answers a refused handshake. Phoenix calls it for the `{:error, reason}` from `connect/1`."
  def handle_error(conn, :rate_limited) do
    conn
    |> Plug.Conn.put_status(:too_many_requests)
    |> Phoenix.Controller.json(%{error: "rate_limit_exceeded"})
  end

  defp header_token(%{connect_info: %{x_headers: headers}}) do
    Enum.find_value(headers, fn {name, value} -> if name == "x-pux-token", do: value end)
  end

  defp header_token(_transport), do: nil

  # Sockets dispatch before any plug, so the peer here is what `conn.remote_ip` is for a
  # REST request, and `x_headers` keeps every X-Forwarded-For line in order.
  defp rate_limit_key(%{connect_info: %{peer_data: %{address: address}, x_headers: headers}}) do
    RateLimit.rate_limit_key(address, for({"x-forwarded-for", value} <- headers, do: value))
  end

  @impl true
  def init(%{record_id: record_id}) do
    topic = Push.delivery_topic(record_id)
    Phoenix.PubSub.subscribe(Pux.PubSub, topic)
    # Nothing needs the record ID from here on, so it can't turn up in a crash report.
    {:ok, %{}}
  end

  @impl true
  def handle_in({text, _opts}, state) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => "ping"}} ->
        frame = {:text, Jason.encode!(%{"type" => "pong"})}
        {:reply, :ok, frame, state}

      _ ->
        {:ok, state}
    end
  end

  def handle_in(_message, state), do: {:ok, state}

  @impl true
  def handle_info({:envelope, delivery_id, envelope}, state) do
    payload =
      Jason.encode!(%{
        "type" => "envelope",
        "delivery_id" => delivery_id,
        "envelope" => envelope
      })

    {:push, {:text, payload}, state}
  end

  def handle_info(:record_deleted, state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
