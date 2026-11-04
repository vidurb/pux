defmodule Pux.Workers.TokenCheckWorker do
  @moduledoc """
  Asks FCM about a quiet device's token without sending it anything. Otherwise a dead token
  on a relay that gets no mail would never be noticed, and neither the device nor the relay
  would ever be removed. On the default queue so that checks can't delay OTP pushes.

  A passing check is recorded so that each token is checked once per `fcm_token_check_days`,
  but doesn't count as contact: `device_max_idle_days` still runs from `last_seen_at`. FCM
  only knows what it has been told: see "Data retention" in README.md for what this can't
  detect.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Pux.Push.FCM
  alias Pux.Records

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"device_id" => device_id}}) do
    case Records.get_device(device_id) do
      nil ->
        :ok

      device ->
        case FCM.check_token(device.push_token) do
          :ok ->
            Records.mark_token_checked(device)

          :unregistered ->
            Records.delete_devices_by_token(device.push_token)
            :ok

          other ->
            other
        end
    end
  end
end
