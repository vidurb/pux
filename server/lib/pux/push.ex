defmodule Pux.Push do
  @moduledoc """
  Encrypt OTP payloads and fan out to registered devices.
  """

  alias Pux.{Crypto, Deliveries, Records}
  alias Pux.Records.Record
  alias Pux.Push.{APNs, FCM}

  require Logger

  @spec deliver_to_record(Record.t(), iodata()) :: :ok
  def deliver_to_record(%Record{} = record, plaintext) when is_binary(plaintext) do
    case Crypto.seal(plaintext, record.public_key) do
      {:ok, ciphertext} ->
        envelope = %{
          "ciphertext" => Crypto.encode_ciphertext(ciphertext)
        }

        record.id
        |> Records.list_devices()
        |> Enum.each(fn device ->
          %{device_id: device.id, envelope: envelope}
          |> Pux.Workers.PushWorker.new()
          |> Oban.insert()
        end)

        if Deliveries.has_desktop_devices?(record.id) do
          case Deliveries.create_pending(record.id, envelope) do
            {:ok, pending} ->
              Phoenix.PubSub.broadcast(
                Pux.PubSub,
                delivery_topic(record.id),
                {:envelope, pending.id, envelope}
              )

            {:error, reason} ->
              Logger.error(
                "Pending delivery persistence failed for record #{record.id}: #{inspect(reason)}"
              )
          end
        end

        :ok

      {:error, reason} ->
        Logger.error("Push encryption failed for record #{record.id}: #{inspect(reason)}")
        :ok
    end
  end

  @spec delivery_topic(Ecto.UUID.t()) :: String.t()
  def delivery_topic(record_id), do: "delivery:#{record_id}"

  @spec dispatch_device(map(), map()) :: :ok | {:error, term()}
  def dispatch_device(%{platform: :fcm, push_token: token}, envelope) do
    FCM.deliver(token, envelope)
    :ok
  end

  def dispatch_device(%{platform: :apns, push_token: token}, envelope) do
    APNs.deliver(token, envelope)
    :ok
  end

  def dispatch_device(%{platform: :desktop}, _envelope) do
    :ok
  end
end
