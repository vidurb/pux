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

  @spec register_device(Ecto.UUID.t(), map()) :: {:ok, Device.t()} | {:error, term()}
  def register_device(record_id, attrs) do
    now = DateTime.utc_now()

    with %Record{} = record <- get_record(record_id),
         {:ok, device} <-
           %Device{}
           |> Device.changeset(
             Map.merge(attrs, %{
               record_id: record.id,
               last_seen_at: now
             })
           )
           |> Repo.insert(
             on_conflict: {:replace, [:platform, :last_seen_at, :updated_at]},
             conflict_target: [:record_id, :push_token]
           ),
         _ <- touch_record!(record) do
      {:ok, device}
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec list_devices(Ecto.UUID.t()) :: [Device.t()]
  def list_devices(record_id) do
    Device
    |> where([d], d.record_id == ^record_id)
    |> Repo.all()
  end

  @spec get_device(Ecto.UUID.t()) :: Device.t() | nil
  def get_device(id), do: Repo.get(Device, id)

  @spec touch_device!(Device.t()) :: Device.t()
  def touch_device!(%Device{} = device) do
    now = DateTime.utc_now(:microsecond)

    device
    |> Ecto.Changeset.change(last_seen_at: now)
    |> Repo.update!()
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

  defp generate_inbox_token do
    alphabet_size = length(@inbox_token_alphabet)

    :crypto.strong_rand_bytes(@token_length)
    |> :binary.bin_to_list()
    |> Enum.map_join(fn byte ->
      <<Enum.at(@inbox_token_alphabet, rem(byte, alphabet_size))::utf8>>
    end)
  end
end
