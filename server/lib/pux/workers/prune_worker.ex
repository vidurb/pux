defmodule Pux.Workers.PruneWorker do
  @moduledoc """
  Enforces retention (see "Data retention" in README.md). Replaces account management.
  `%{"scope" => "deliveries"}` prunes only pending deliveries (run every few minutes).

  FCM devices are never removed here: only FCM can say that one is dead, so quiet tokens are
  queued for `Pux.Workers.TokenCheckWorker` to ask.
  """
  use Oban.Worker, queue: :default

  alias Pux.{Deliveries, Records}
  alias Pux.Push.FCM
  alias Pux.Workers.TokenCheckWorker

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scope" => "deliveries"}}) do
    count = Deliveries.prune_stale(delivery_ttl())
    if count > 0, do: Logger.info("Pruned #{count} pending deliveries")
    :ok
  end

  def perform(_job) do
    config = Application.get_env(:pux, :pruner, [])
    # Devices first: a record that loses its last one here gets its grace period tonight.
    devices = Records.prune_stale_desktop_devices(config[:desktop_device_ttl_days] || 90)
    records = Records.prune_deviceless_records(config[:deviceless_record_ttl_days] || 30)
    deliveries = Deliveries.prune_stale(delivery_ttl())
    checks = enqueue_token_checks(config[:fcm_token_check_days] || 30)

    Logger.info(
      "Pruned #{records} records, #{devices} desktop devices, and #{deliveries} pending " <>
        "deliveries; checking #{checks} quiet FCM tokens"
    )

    :ok
  end

  defp enqueue_token_checks(days) do
    if FCM.enabled?() do
      days
      |> Records.list_quiet_fcm_device_ids()
      |> Enum.map(&TokenCheckWorker.new(%{device_id: &1}))
      |> Oban.insert_all()
      |> length()
    else
      0
    end
  end

  defp delivery_ttl, do: Application.get_env(:pux, :pruner, [])[:delivery_ttl_minutes] || 10
end
