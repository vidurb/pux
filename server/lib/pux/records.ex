defmodule Pux.Records do
  @moduledoc """
  Record and device persistence. A record is the only identity primitive.
  """

  import Ecto.Query

  alias Pux.Crypto
  alias Pux.Repo
  alias Pux.Records.{Device, Record}

  @token_length 24
  @inbox_token_alphabet ~c"abcdefghijklmnopqrstuvwxyz0123456789"

  @type enrollment :: %{
          record_id: Ecto.UUID.t(),
          inbox_token: String.t(),
          inbox_address: String.t(),
          public_key: String.t()
        }

  @max_inbox_token_attempts 5

  @spec create_record(binary()) :: {:ok, enrollment()} | {:error, term()}
  def create_record(public_key) when is_binary(public_key) do
    now = DateTime.utc_now(:microsecond)
    insert_record_with_token(public_key, now, 0)
  end

  defp insert_record_with_token(public_key, now, attempt)
       when attempt < @max_inbox_token_attempts do
    attrs = %{
      inbox_token: generate_inbox_token(),
      public_key: public_key,
      last_active_at: now
    }

    case %Record{}
         |> Record.changeset(attrs)
         |> Repo.insert() do
      {:ok, record} ->
        {:ok, build_enrollment(record)}

      {:error, %Ecto.Changeset{} = changeset} ->
        if inbox_token_collision?(changeset) do
          insert_record_with_token(public_key, now, attempt + 1)
        else
          {:error, changeset}
        end
    end
  end

  defp insert_record_with_token(_public_key, _now, _attempt) do
    {:error, :inbox_token_collision}
  end

  defp inbox_token_collision?(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :inbox_token) do
      {_, opts} when is_list(opts) ->
        Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end
  end

  @spec get_record(Ecto.UUID.t()) :: Record.t() | nil
  def get_record(id), do: Repo.get(Record, id)

  @spec get_record_by_inbox_token(String.t()) :: Record.t() | nil
  def get_record_by_inbox_token(token) do
    Repo.get_by(Record, inbox_token: token)
  end

  @spec touch_record!(Record.t()) :: Record.t()
  def touch_record!(%Record{} = record) do
    now = DateTime.utc_now()

    record
    |> Ecto.Changeset.change(last_active_at: now)
    |> Repo.update!()
  end

  @doc "Like `touch_record!/1`, but returns `{:error, :not_found}` if the record is gone."
  @spec touch_record(Record.t()) :: :ok | {:error, :not_found}
  def touch_record(%Record{id: id}) do
    case Repo.update_all(from(r in Record, where: r.id == ^id),
           set: [last_active_at: DateTime.utc_now()]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  @doc """
  Registers (or refreshes) a device. Re-registering an existing push token never
  counts against the per-record device cap.
  """
  @spec register_device(Ecto.UUID.t(), map()) ::
          {:ok, Device.t()} | {:error, :not_found | :too_many_devices | Ecto.Changeset.t()}
  def register_device(record_id, attrs) do
    Repo.transaction(fn ->
      with %Record{} = record <- lock_record(record_id),
           :ok <- check_device_cap(record.id, attrs[:push_token]),
           {:ok, device} <- upsert_device(record, attrs) do
        touch_record!(record)
        device
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Serializes registrations per record so concurrent requests can't overshoot the cap.
  defp lock_record(record_id) do
    Record
    |> where([r], r.id == ^record_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp check_device_cap(record_id, push_token) do
    existing? =
      is_binary(push_token) and
        Repo.exists?(
          where(Device, [d], d.record_id == ^record_id and d.push_token == ^push_token)
        )

    count = Repo.aggregate(where(Device, [d], d.record_id == ^record_id), :count)

    if existing? or count < max_devices(), do: :ok, else: {:error, :too_many_devices}
  end

  defp upsert_device(record, attrs) do
    %Device{}
    |> Device.changeset(
      Map.merge(attrs, %{record_id: record.id, last_seen_at: DateTime.utc_now()})
    )
    |> Repo.insert(
      on_conflict: {:replace, [:platform, :last_seen_at, :updated_at]},
      conflict_target: [:record_id, :push_token]
    )
  end

  defp max_devices do
    Application.get_env(:pux, :records, [])
    |> Keyword.get(:max_devices, 10)
  end

  @spec list_devices(Ecto.UUID.t()) :: [Device.t()]
  def list_devices(record_id) do
    Device
    |> where([d], d.record_id == ^record_id)
    |> Repo.all()
  end

  @doc "Devices that receive push notifications (desktop clients use pending deliveries)."
  @spec list_push_devices(Ecto.UUID.t()) :: [Device.t()]
  def list_push_devices(record_id) do
    Device
    |> where([d], d.record_id == ^record_id and d.platform != :desktop)
    |> Repo.all()
  end

  @spec get_device(Ecto.UUID.t()) :: Device.t() | nil
  def get_device(id), do: Repo.get(Device, id)

  @doc "Bumps last_seen_at; a device deleted concurrently is not an error."
  @spec touch_device(Device.t()) :: {:ok, Device.t()} | {:error, term()}
  def touch_device(%Device{} = device) do
    now = DateTime.utc_now(:microsecond)

    device
    |> Ecto.Changeset.change(last_seen_at: now)
    |> Repo.update(stale_error_field: :id)
  end

  @spec delete_devices_by_token(String.t()) :: non_neg_integer()
  def delete_devices_by_token(push_token) do
    {count, _} =
      Device
      |> where([d], d.push_token == ^push_token)
      |> Repo.delete_all()

    count
  end

  @doc "Deletes a device, scoped to its record."
  @spec delete_record_device(Ecto.UUID.t(), String.t()) :: :ok | {:error, :not_found}
  def delete_record_device(record_id, device_id)
      when is_binary(record_id) and is_binary(device_id) do
    with {:ok, device_id} <- Ecto.UUID.cast(device_id),
         {1, _} <-
           Device
           |> where([d], d.id == ^device_id and d.record_id == ^record_id)
           |> Repo.delete_all() do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Deletes a record; devices and pending deliveries cascade in the database. Open
  delivery sockets for the record are told to close. Idempotent.
  """
  @spec delete_record(Ecto.UUID.t()) :: :ok
  def delete_record(record_id) when is_binary(record_id) do
    {count, _} =
      Record
      |> where([r], r.id == ^record_id)
      |> Repo.delete_all()

    if count > 0 do
      Phoenix.PubSub.broadcast(Pux.PubSub, Pux.Push.delivery_topic(record_id), :record_deleted)
    end

    :ok
  end

  @spec delete_device(Device.t()) :: {:ok, Device.t()} | {:error, term()}
  def delete_device(%Device{} = device), do: Repo.delete(device)

  @spec prune_stale_records(non_neg_integer()) :: non_neg_integer()
  def prune_stale_records(ttl_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-ttl_days * 86_400, :second)

    {count, _} =
      Record
      |> where([r], r.last_active_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  @spec prune_stale_devices(non_neg_integer()) :: non_neg_integer()
  def prune_stale_devices(ttl_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-ttl_days * 86_400, :second)

    {count, _} =
      Device
      |> where([d], d.last_seen_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  defp build_enrollment(%Record{} = record) do
    mail_domain = Application.get_env(:pux, :smtp)[:mail_domain] || "localhost"

    %{
      record_id: record.id,
      inbox_token: record.inbox_token,
      inbox_address: "#{record.inbox_token}@#{mail_domain}",
      public_key: Crypto.encode_key(record.public_key)
    }
  end

  # Rejection sampling: bytes >= 252 (7 * 36) are discarded so every symbol is equally likely.
  @inbox_token_alphabet_size length(@inbox_token_alphabet)
  @inbox_token_byte_limit 256 - rem(256, @inbox_token_alphabet_size)

  defp generate_inbox_token, do: generate_inbox_token([], @token_length)

  defp generate_inbox_token(acc, 0), do: acc |> Enum.reverse() |> List.to_string()

  defp generate_inbox_token(acc, remaining) do
    acc =
      :crypto.strong_rand_bytes(remaining)
      |> :binary.bin_to_list()
      |> Enum.filter(&(&1 < @inbox_token_byte_limit))
      |> Enum.reduce(acc, fn byte, acc ->
        [Enum.at(@inbox_token_alphabet, rem(byte, @inbox_token_alphabet_size)) | acc]
      end)

    generate_inbox_token(acc, @token_length - length(acc))
  end
end
