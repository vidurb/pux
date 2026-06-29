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
          public_key: String.t(),
          private_key: String.t(),
          qr_payload: map()
        }

  @spec create_record() :: {:ok, enrollment()} | {:error, term()}
  def create_record do
    now = DateTime.utc_now()
    %{public_key: public_key, private_key: private_key} = Crypto.generate_keypair()
    inbox_token = generate_inbox_token()

    attrs = %{
      inbox_token: inbox_token,
      public_key: public_key,
      last_active_at: now
    }

    with {:ok, record} <-
           %Record{}
           |> Record.changeset(attrs)
           |> Repo.insert() do
      enrollment = build_enrollment(record, private_key)
      {:ok, enrollment}
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

  defp build_enrollment(%Record{} = record, private_key) do
    mail_domain = Application.get_env(:pux, :smtp)[:mail_domain] || "localhost"
    host = endpoint_host()

    qr_payload = %{
      v: 1,
      record_id: record.id,
      private_key: Crypto.encode_key(private_key),
      public_key: Crypto.encode_key(record.public_key),
      inbox: "#{record.inbox_token}@#{mail_domain}",
      server: "https://#{host}"
    }

    %{
      record_id: record.id,
      inbox_token: record.inbox_token,
      inbox_address: "#{record.inbox_token}@#{mail_domain}",
      public_key: Crypto.encode_key(record.public_key),
      private_key: Crypto.encode_key(private_key),
      qr_payload: qr_payload
    }
  end

  defp endpoint_host do
    case Application.get_env(:pux, PuxWeb.Endpoint)[:url] do
      [host: host] -> host
      _ -> "localhost"
    end
  end

  defp generate_inbox_token do
    for _ <- 1..@token_length, into: "" do
      <<Enum.random(@inbox_token_alphabet)::utf8>>
    end
  end
end
