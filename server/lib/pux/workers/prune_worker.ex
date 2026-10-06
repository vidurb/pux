defmodule Pux.Workers.PruneWorker do
  @moduledoc """
  Deletes stale records, devices and pending deliveries. Replaces account management.
  `%{"scope" => "deliveries"}` prunes only pending deliveries (run every few minutes).
  """
  use Oban.Worker, queue: :default

  alias Pux.{Deliveries, Records}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scope" => "deliveries"}}) do
    count = Deliveries.prune_stale(delivery_ttl())
    if count > 0, do: Logger.info("Pruned #{count} pending deliveries")
    :ok
  end

  def perform(_job) do
    config = Application.get_env(:pux, :pruner, [])
    records = Records.prune_stale_records(config[:record_ttl_days] || 90)
    devices = Records.prune_stale_devices(config[:device_ttl_days] || 30)
    deliveries = Deliveries.prune_stale(delivery_ttl())

    Logger.info(
      "Pruned #{records} records, #{devices} devices, and #{deliveries} pending deliveries"
    )

    :ok
  end

  defp delivery_ttl, do: Application.get_env(:pux, :pruner, [])[:delivery_ttl_minutes] || 10
end
