defmodule Pux.Workers.PruneWorker do
  @moduledoc """
  Deletes stale records and devices. Replaces account management.
  """
  use Oban.Worker, queue: :default

  alias Pux.Records

  @impl Oban.Worker
  def perform(_job) do
    record_ttl = Application.get_env(:pux, :pruner)[:record_ttl_days] || 90
    device_ttl = Application.get_env(:pux, :pruner)[:device_ttl_days] || 30
    delivery_ttl = Application.get_env(:pux, :pruner)[:delivery_ttl_minutes] || 10

    records = Records.prune_stale_records(record_ttl)
    devices = Records.prune_stale_devices(device_ttl)
    deliveries = Pux.Deliveries.prune_stale(delivery_ttl)

    require Logger
    Logger.info(
      "Pruned #{records} records, #{devices} devices, and #{deliveries} pending deliveries"
    )

    :ok
  end
end
