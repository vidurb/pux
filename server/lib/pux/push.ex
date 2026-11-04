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
        |> Records.list_push_devices()
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
              Logger.error("Pending delivery persistence failed: #{failure_reason(reason)}")
          end
        end

        :ok

      {:error, reason} ->
        Logger.error("Push encryption failed: #{failure_reason(reason)}")
        :ok
    end
  end

  # The record ID is a credential, and inspecting a changeset or an unknown term could print
  # it, so log only what can't carry it: field names, validation messages and exception types.
  defp failure_reason(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, ", ", fn {field, {message, _opts}} -> "#{field} #{message}" end)
  end

  defp failure_reason(%{__exception__: true, __struct__: type}), do: inspect(type)
  defp failure_reason(reason) when is_atom(reason), do: inspect(reason)
  defp failure_reason(_reason), do: "unexpected error"

  @spec delivery_topic(Ecto.UUID.t()) :: String.t()
  def delivery_topic(record_id), do: "delivery:#{record_id}"

  @spec dispatch_device(map(), map()) :: FCM.result()
  def dispatch_device(%{platform: :fcm, push_token: token}, envelope) do
    FCM.deliver(token, envelope)
  end

  def dispatch_device(%{platform: :apns, push_token: token}, envelope) do
    APNs.deliver(token, envelope)
  end

  def dispatch_device(%{platform: :desktop}, _envelope) do
    :ok
  end
end
