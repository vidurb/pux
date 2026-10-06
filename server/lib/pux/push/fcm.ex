defmodule Pux.Push.FCM do
  @moduledoc """
  Firebase Cloud Messaging HTTP v1 data messages. Payload is already E2E encrypted.
  """

  require Logger

  @fcm_url "https://fcm.googleapis.com/v1/projects"

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
      {:error, reason} ->
        Logger.error("FCM service account JSON is invalid: #{inspect(reason)}")
        nil

      _ ->
        nil
    end
  end

  @spec deliver(String.t(), map()) :: result()
  def deliver(push_token, envelope) when is_binary(push_token) and is_map(envelope) do
    if enabled?() do
      do_deliver(config()[:project_id], push_token, envelope)
    else
      Logger.debug("FCM disabled; would push to #{String.slice(push_token, 0, 8)}...")
      :ok
    end
  end

  @doc false
  def message(push_token, envelope) do
    %{
      message: %{
        token: push_token,
        data: %{"ciphertext" => envelope["ciphertext"] || envelope[:ciphertext]},
        android: %{priority: "HIGH", ttl: "300s"}
      }
    }
  end

  defp do_deliver(project_id, push_token, envelope) do
    url = "#{@fcm_url}/#{project_id}/messages:send"

    with {:ok, token} <- fetch_token(),
         {:ok, %Finch.Response{status: status, body: body}} <-
           Finch.build(
             :post,
             url,
             [
               {"authorization", "Bearer #{token.token}"},
               {"content-type", "application/json"}
             ],
             Jason.encode!(message(push_token, envelope))
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

  def classify_response(404, _body) do
    Logger.info("FCM token unregistered")
    :unregistered
  end

  def classify_response(status, body) when status in [400, 403] do
    Logger.error("FCM push rejected (#{status}): #{error_status(body)}")
    {:cancel, {:fcm, status}}
  end

  def classify_response(status, body) do
    Logger.warning("FCM push failed (#{status}): #{error_status(body)}")
    {:error, {:fcm, status}}
  end

  defp error_status(body) do
    case Jason.decode(body || "") do
      {:ok, %{"error" => %{"status" => status}}} -> status
      _ -> "unknown"
    end
  end
end
