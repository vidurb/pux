defmodule Pux.Push do
  @moduledoc """
  Encrypt OTP payloads and fan out to registered devices.
  """

  alias Pux.{Crypto, Records}
  alias Pux.Records.Record
  alias Pux.Push.{APNs, FCM}

  require Logger

  @spec deliver_to_record(Record.t(), iodata()) :: :ok
  def deliver_to_record(%Record{} = record, plaintext) when is_binary(plaintext) do
    case Crypto.seal(plaintext, record.public_key) do
      {:ok, ciphertext} ->
        envelope = %{
          ciphertext: Crypto.encode_ciphertext(ciphertext)
        }

        record.id
        |> Records.list_devices()
        |> Enum.each(fn device ->
          dispatch(device, envelope)
        end)

        :ok

      {:error, reason} ->
        Logger.error("Push encryption failed for record #{record.id}: #{inspect(reason)}")
        :ok
    end
  end

  defp dispatch(%{platform: :fcm, push_token: token}, envelope) do
    FCM.deliver(token, envelope)
  end

  defp dispatch(%{platform: :apns, push_token: token}, envelope) do
    APNs.deliver(token, envelope)
  end
end
