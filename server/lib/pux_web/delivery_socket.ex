defmodule PuxWeb.DeliverySocket do
  @moduledoc """
  WebSocket transport for desktop clients to receive encrypted OTP envelopes.
  """
  @behaviour Phoenix.Socket.Transport

  alias Pux.Push

  @impl true
  def child_spec(_opts) do
    # No child processes needed.
    :ignore
  end

  @impl true
  def connect(conn) do
    with token when is_binary(token) <- conn.query_params["token"],
         true <- valid_uuid?(token) do
      {:ok, %{record_id: token}}
    else
      _ -> :error
    end
  end

  @impl true
  def init(%{record_id: record_id} = state) do
    topic = Push.delivery_topic(record_id)
    Phoenix.PubSub.subscribe(Pux.PubSub, topic)
    {:ok, state}
  end

  @impl true
  def handle_in({text, _opts}, state) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => "ping"}} ->
        frame = {:text, Jason.encode!(%{"type" => "pong"})}
        {:reply, frame, state}

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

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

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
