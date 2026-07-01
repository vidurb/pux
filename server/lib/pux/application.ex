defmodule Pux.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PuxWeb.Telemetry,
        Pux.Repo,
        {Phoenix.PubSub, name: Pux.PubSub},
        {Finch, name: Pux.Finch},
        {Oban, Application.fetch_env!(:pux, Oban)},
        PuxWeb.Endpoint,
        Pux.SMTP.Supervisor
      ]
      |> maybe_start_goth()

    opts = [strategy: :one_for_one, name: Pux.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_start_goth(children) do
    case Application.get_env(:pux, :fcm) do
      %{enabled: true, service_account_json: json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, credentials} ->
            [{Goth, name: Pux.Goth, source: {:service_account, credentials}} | children]

          {:error, reason} ->
            require Logger
            Logger.error("FCM service account JSON is invalid: #{inspect(reason)}")
            children
        end

      _ ->
        children
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    PuxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
