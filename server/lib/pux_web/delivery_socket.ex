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

  # The record ID is sent in the `x-pux-token` header; the `token` query param
  # is a fallback for older clients and ends up in proxy access logs.
  @impl true
  def connect(%{params: params} = transport) do
    with token when is_binary(token) <- header_token(transport) || params["token"],
         true <- valid_uuid?(token),
         %Pux.Records.Record{} <- Pux.Records.get_record(token) do
      {:ok, %{record_id: token}}
    else
      _ -> :error
    end
  end

  defp header_token(%{connect_info: %{x_headers: headers}}) do
    Enum.find_value(headers, fn {name, value} -> if name == "x-pux-token", do: value end)
  end

  defp header_token(_transport), do: nil

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
