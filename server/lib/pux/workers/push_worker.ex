defmodule Pux.Workers.PushWorker do
  @moduledoc """
  Delivers encrypted push notifications asynchronously via FCM/APNs.
  """
  use Oban.Worker, queue: :push, max_attempts: 5

  alias Pux.Push
  alias Pux.Records

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"device_id" => device_id, "envelope" => envelope}}) do
    case Records.get_device(device_id) do
      nil ->
        :ok

      device ->
        Push.dispatch_device(device, envelope)
        Records.touch_device!(device)
        :ok
    end
  end
end
