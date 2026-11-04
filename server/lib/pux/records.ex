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

  @doc """
  The record behind an inbox token, if mail to it can reach a device. A single query, so that
  an unknown address and a relay with no devices look the same to a sender, in time as well
  as in the reply.
  """
  @spec get_deliverable_record_by_inbox_token(String.t()) :: Record.t() | nil
  def get_deliverable_record_by_inbox_token(token) do
    from(r in Record, as: :record)
    |> where([r], r.inbox_token == ^token and exists(device_of_record()))
    |> Repo.one()
  end

  @spec touch_record!(Record.t()) :: Record.t()
  def touch_record!(%Record{} = record) do
    now = DateTime.utc_now()

    record
    |> Ecto.Changeset.change(last_active_at: now)
    |> Repo.update!()
  end

  @doc """
  Marks mail as delivered to a record that can still receive it. Returns
  `{:error, :no_devices}` if the record went away or lost its last device after the
  recipient was accepted: there is nobody to deliver to, and that mail must not restart the
  clock of a relay on its way out.
  """
  @spec touch_record(Record.t()) :: :ok | {:error, :no_devices}
  def touch_record(%Record{id: id}) do
    query = from(r in Record, as: :record, where: r.id == ^id and exists(device_of_record()))

    case Repo.update_all(query, set: [last_active_at: DateTime.utc_now()]) do
      {1, _} -> :ok
      {0, _} -> {:error, :no_devices}
    end
  end

  defp device_of_record do
    from(d in Device, where: d.record_id == parent_as(:record).id, select: 1)
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

  @doc "Deletes a token the push service reports dead, on every record that has it."
  @spec delete_devices_by_token(String.t()) :: non_neg_integer()
  def delete_devices_by_token(push_token) do
    Device
    |> where([d], d.push_token == ^push_token)
    |> delete_lost_devices()
  end

  # The server, not the user, decided these devices are gone, and it can be wrong about one
  # that is merely switched off or has a new token. Restarting the record's clock gives that
  # app the full `deviceless_record_ttl_days` to re-register, however quiet the relay was.
  defp delete_lost_devices(query) do
    {:ok, count} =
      Repo.transaction(fn ->
        {count, record_ids} = query |> select([d], d.record_id) |> Repo.delete_all()

        Repo.update_all(from(r in Record, where: r.id in ^Enum.uniq(record_ids)),
          set: [last_active_at: DateTime.utc_now()]
        )

        count
      end)

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

  @doc "Deletes records with no devices whose `last_active_at` is older than the TTL."
  @spec prune_deviceless_records(non_neg_integer()) :: non_neg_integer()
  def prune_deviceless_records(ttl_days) do
    cutoff = days_ago(ttl_days)

    {count, _} =
      from(r in Record, as: :record)
      |> where([r], r.last_active_at < ^cutoff and not exists(device_of_record()))
      |> Repo.delete_all()

    count
  end

  @doc """
  Deletes devices that haven't registered within the TTL, except FCM devices: FCM reports
  those itself. Everything else has no such signal.
  """
  @spec prune_stale_desktop_devices(non_neg_integer()) :: non_neg_integer()
  def prune_stale_desktop_devices(ttl_days) do
    cutoff = days_ago(ttl_days)

    Device
    |> where([d], d.platform != :fcm and d.last_seen_at < ^cutoff)
    |> delete_lost_devices()
  end

  @doc """
  Deletes any device with no registration or accepted push within the limit. Unlike FCM's
  answer, this also covers tokens nothing would ever report, such as an uninstalled iOS app.
  """
  @spec prune_long_idle_devices(non_neg_integer()) :: non_neg_integer()
  def prune_long_idle_devices(max_idle_days) do
    cutoff = days_ago(max_idle_days)

    Device
    |> where([d], d.last_seen_at < ^cutoff)
    |> delete_lost_devices()
  end

  @doc "IDs of FCM devices with no registration, accepted push or passed check within the days."
  @spec list_quiet_fcm_device_ids(non_neg_integer()) :: [Ecto.UUID.t()]
  def list_quiet_fcm_device_ids(days) do
    cutoff = days_ago(days)

    Device
    |> where([d], d.platform == :fcm and d.last_seen_at < ^cutoff)
    |> where([d], is_nil(d.token_checked_at) or d.token_checked_at < ^cutoff)
    |> select([d], d.id)
    |> Repo.all()
  end

  @doc "Records a passed token check. Leaves `last_seen_at`, and so the age limits, alone."
  @spec mark_token_checked(Device.t()) :: :ok
  def mark_token_checked(%Device{id: id}) do
    Repo.update_all(from(d in Device, where: d.id == ^id),
      set: [token_checked_at: DateTime.utc_now(:microsecond)]
    )

    :ok
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

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
