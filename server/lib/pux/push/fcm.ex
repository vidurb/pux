defmodule Pux.Push.FCM do
  @moduledoc """
  Firebase Cloud Messaging HTTP v1 messages. Payload is already E2E encrypted.

  Android gets a data-only message that the app decrypts and shows. iOS gets an
  alert with a generic placeholder and `mutable-content`, which the app's
  Notification Service Extension replaces with the decrypted content. FCM
  delivers the `data` keys to iOS as top-level keys of the APNs payload.
  """

  require Logger

  @fcm_url "https://fcm.googleapis.com/v1/projects"
  @fcm_error_type "type.googleapis.com/google.firebase.fcm.v1.FcmError"
  @bad_request_type "type.googleapis.com/google.rpc.BadRequest"
  @ttl_seconds 300

  @type result :: :ok | :unregistered | {:error, term()} | {:cancel, term()}

  @doc "FCM config from `config :pux, :fcm` (keyword list or map)."
  def config, do: Application.get_env(:pux, :fcm, [])

  @spec enabled?() :: boolean()
  def enabled? do
    cfg = config()
    cfg[:enabled] == true and is_binary(cfg[:project_id])
  end

  @doc "Goth child spec when FCM is enabled with valid credentials, else nil."
  def goth_child_spec do
    cfg = config()

    with true <- enabled?(),
         json when is_binary(json) <- cfg[:service_account_json],
         {:ok, credentials} <- Jason.decode(json) do
      {Goth, name: Pux.Goth, source: {:service_account, credentials}}
    else
      # The decode error holds the whole input, including the private key.
      {:error, %Jason.DecodeError{position: position}} ->
        Logger.error("FCM service account JSON is invalid at byte #{position}")
        nil

      _ ->
        nil
    end
  end

  @spec deliver(String.t(), map()) :: result()
  def deliver(push_token, envelope) when is_binary(push_token) and is_map(envelope) do
    send_message(message(push_token, envelope))
  end

  @doc """
  Asks FCM whether a token is still valid, with a dry-run send (`validate_only`): nothing
  reaches the device. The message has the shape of a real one, so that the only thing wrong
  with it can be the token.
  """
  @spec check_token(String.t()) :: result()
  def check_token(push_token) when is_binary(push_token) do
    push_token
    |> message(%{"ciphertext" => ""})
    |> Map.put(:validate_only, true)
    |> send_message()
  end

  defp send_message(body) do
    if enabled?() do
      do_send(config()[:project_id], body)
    else
      Logger.debug("FCM disabled; would push")
      :ok
    end
  end

  @doc false
  def message(push_token, envelope) do
    %{
      message: %{
        token: push_token,
        data: %{"ciphertext" => envelope["ciphertext"] || envelope[:ciphertext]},
        android: %{priority: "HIGH", ttl: "#{@ttl_seconds}s"},
        apns: %{
          headers: %{
            "apns-push-type" => "alert",
            "apns-priority" => "10",
            "apns-expiration" => Integer.to_string(System.os_time(:second) + @ttl_seconds)
          },
          payload: %{
            aps: %{
              alert: %{title: "New code", body: "Open pux to view"},
              "mutable-content": 1,
              sound: "default"
            }
          }
        }
      }
    }
  end

  defp do_send(project_id, body) do
    url = "#{config()[:base_url] || @fcm_url}/#{project_id}/messages:send"

    with {:ok, token} <- fetch_token(),
         {:ok, %Finch.Response{status: status, body: body}} <-
           Finch.build(
             :post,
             url,
             [
               {"authorization", "Bearer #{token.token}"},
               {"content-type", "application/json"}
             ],
             Jason.encode!(body)
           )
           |> Finch.request(Pux.Finch) do
      classify_response(status, body)
    else
      {:error, reason} ->
        Logger.warning("FCM push error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_token do
    Goth.fetch(Pux.Goth)
  catch
    :exit, reason -> {:error, {:goth_unavailable, reason}}
  end

  @doc false
  @spec classify_response(non_neg_integer(), binary()) :: result()
  def classify_response(status, _body) when status in 200..299, do: :ok

  # Devices are removed on this signal alone and don't come back until the app next starts,
  # so a 404 that doesn't name the token (a wrong project ID, a proxy) must not count.
  def classify_response(404 = status, body) do
    if fcm_error_code(body) == "UNREGISTERED" do
      Logger.info("FCM token unregistered")
      :unregistered
    else
      Logger.warning("FCM push failed (#{status}): #{error_status(body)}")
      {:error, {:fcm, status}}
    end
  end

  def classify_response(400 = status, body) do
    if invalid_token?(body) do
      Logger.info("FCM token invalid")
      :unregistered
    else
      Logger.error("FCM push rejected (#{status}): #{error_status(body)}")
      {:cancel, {:fcm, status}}
    end
  end

  # Not treated as a dead token even for SENDER_ID_MISMATCH: wrong server credentials look
  # the same, and would remove every device.
  def classify_response(403 = status, body) do
    Logger.error("FCM push rejected (#{status}): #{error_status(body)}")
    {:cancel, {:fcm, status}}
  end

  def classify_response(status, body) do
    Logger.warning("FCM push failed (#{status}): #{error_status(body)}")
    {:error, {:fcm, status}}
  end

  defp fcm_error_code(body) do
    Enum.find_value(error_details(body), fn
      %{"@type" => @fcm_error_type, "errorCode" => code} -> code
      _ -> nil
    end)
  end

  # INVALID_ARGUMENT also covers a bad payload, so it has to blame the token specifically.
  defp invalid_token?(body) do
    Enum.any?(error_details(body), fn
      %{"@type" => @bad_request_type, "fieldViolations" => violations} when is_list(violations) ->
        Enum.any?(violations, &match?(%{"field" => "message.token"}, &1))

      _ ->
        false
    end)
  end

  defp error_details(body) do
    case Jason.decode(body || "") do
      {:ok, %{"error" => %{"details" => details}}} when is_list(details) -> details
      _ -> []
    end
  end

  defp error_status(body) do
    case Jason.decode(body || "") do
      {:ok, %{"error" => %{"status" => status}}} -> status
      _ -> "unknown"
    end
  end
end
