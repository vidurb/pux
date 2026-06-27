defmodule Pux.Push.FCM.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Supervisor.init([], strategy: :one_for_one)
  end
end

defmodule Pux.Push.FCM do
  @moduledoc """
  Firebase Cloud Messaging HTTP v1 data messages. Payload is already E2E encrypted.
  """

  require Logger

  @fcm_url "https://fcm.googleapis.com/v1/projects"

  @spec deliver(String.t(), map()) :: :ok
  def deliver(push_token, envelope) when is_binary(push_token) and is_map(envelope) do
    case Application.get_env(:pux, :fcm) do
      %{enabled: true, project_id: project_id} when is_binary(project_id) ->
        do_deliver(project_id, push_token, envelope)

      _ ->
        Logger.debug("FCM disabled; would push to #{String.slice(push_token, 0, 8)}...")
        :ok
    end
  end

  defp do_deliver(project_id, push_token, envelope) do
    url = "#{@fcm_url}/#{project_id}/messages:send"

    body = %{
      message: %{
        token: push_token,
        data: %{
          "ciphertext" => envelope.ciphertext
        },
        android: %{
          priority: "HIGH"
        }
      }
    }

    with {:ok, token} <- Goth.fetch(Pux.Goth),
         {:ok, %Finch.Response{status: status}} when status in 200..299 <-
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
      :ok
    else
      {:ok, %Finch.Response{status: 404}} ->
        Logger.info("FCM token unregistered: #{String.slice(push_token, 0, 8)}...")
        maybe_prune_token(push_token)
        :ok

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.warning("FCM push failed (#{status}): #{body}")
        :ok

      {:error, reason} ->
        Logger.warning("FCM push error: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_prune_token(push_token) do
    import Ecto.Query
    alias Pux.{Records.Device, Repo}

    Device
    |> where([d], d.push_token == ^push_token)
    |> Repo.delete_all()
  end
end
