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

    records = Records.prune_stale_records(record_ttl)
    devices = Records.prune_stale_devices(device_ttl)

    require Logger
    Logger.info("Pruned #{records} records and #{devices} devices")
    :ok
  end
end
