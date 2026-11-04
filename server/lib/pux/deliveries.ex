defmodule Pux.Deliveries do
  @moduledoc """
  Pending delivery persistence for desktop clients (WebSocket + poll fallback).
  """

  import Ecto.Query

  alias Pux.Repo
  alias Pux.Records.PendingDelivery

  @spec create_pending(Ecto.UUID.t(), map()) :: {:ok, PendingDelivery.t()} | {:error, term()}
  def create_pending(record_id, envelope) when is_binary(record_id) and is_map(envelope) do
    %PendingDelivery{}
    |> PendingDelivery.changeset(%{record_id: record_id, envelope: envelope})
    |> Repo.insert()
  end

  @max_page 50

  @doc "The oldest pending deliveries for a record, at most #{@max_page}."
  @spec list_pending(Ecto.UUID.t()) :: [PendingDelivery.t()]
  def list_pending(record_id) when is_binary(record_id) do
    PendingDelivery
    |> where([d], d.record_id == ^record_id)
    |> order_by([d], asc: d.inserted_at, asc: d.id)
    |> limit(@max_page)
    |> Repo.all()
  end

  @spec ack_pending(Ecto.UUID.t(), String.t()) :: :ok | {:error, :not_found}
  def ack_pending(record_id, delivery_id)
      when is_binary(record_id) and is_binary(delivery_id) do
    with {:ok, delivery_id} <- Ecto.UUID.cast(delivery_id),
         {1, _} <-
           PendingDelivery
           |> where([d], d.id == ^delivery_id and d.record_id == ^record_id)
           |> Repo.delete_all() do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @spec prune_stale(non_neg_integer()) :: non_neg_integer()
  def prune_stale(ttl_minutes) do
    cutoff = DateTime.utc_now() |> DateTime.add(-ttl_minutes * 60, :second)

    {count, _} =
      PendingDelivery
      |> where([d], d.inserted_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  @spec has_desktop_devices?(Ecto.UUID.t()) :: boolean()
  def has_desktop_devices?(record_id) when is_binary(record_id) do
    alias Pux.Records.Device

    Device
    |> where([d], d.record_id == ^record_id and d.platform == :desktop)
    |> Repo.exists?()
  end
end
