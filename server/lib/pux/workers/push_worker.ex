defmodule Pux.Workers.PushWorker do
  @moduledoc """
  Delivers encrypted push notifications asynchronously via FCM/APNs.
  OTPs go stale in minutes, so retries are short.
  """
  use Oban.Worker, queue: :push, max_attempts: 4

  alias Pux.Push
  alias Pux.Records

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"device_id" => device_id, "envelope" => envelope}}) do
    case Records.get_device(device_id) do
      nil ->
        :ok

      device ->
        case Push.dispatch_device(device, envelope) do
          :ok ->
            Records.touch_device(device)
            :ok

          :unregistered ->
            Records.delete_devices_by_token(device.push_token)
            :ok

          other ->
            other
        end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: attempt * 10
end
