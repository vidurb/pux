defmodule Pux.Push do
  @moduledoc """
  Encrypt OTP payloads and fan out to registered devices.
  """

  alias Pux.{Crypto, Deliveries, Records}
  alias Pux.Records.Record
  alias Pux.Push.FCM

  require Logger

  @test_sender "pux test"

  @doc """
  Sends a made-up code to every device on the record, by the same path as a real one: the
  payload is an ordinary OTP (so every app version shows it, as "OTP from #{@test_sender}"),
  sealed to the record's key and handed to `deliver_to_record/2`. Nothing is stored apart
  from the sealed envelopes, which expire like any others.

  Returns the code, so the app can say what to look for, and how many devices it went to.
  A record with no devices gets `{:error, :no_devices}`: nothing could arrive anywhere.
  """
  @spec send_test_code(Record.t()) ::
          {:ok, %{otp: String.t(), devices: pos_integer()}} | {:error, :no_devices}
  def send_test_code(%Record{} = record) do
    case length(Records.list_devices(record.id)) do
      0 ->
        {:error, :no_devices}

      devices ->
        otp = test_code()

        payload = %{
          type: "otp",
          otp: otp,
          sender: @test_sender,
          sender_domain: nil,
          verified: true,
          received_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          parser: "test"
        }

        :ok = deliver_to_record(record, Jason.encode!(payload))
        {:ok, %{otp: otp, devices: devices}}
    end
  end

  # Six digits with no leading zero, so it reads the same however it's displayed.
  defp test_code, do: Integer.to_string(100_000 + :rand.uniform(900_000) - 1)

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

  def dispatch_device(%{platform: :desktop}, _envelope) do
    :ok
  end
end
