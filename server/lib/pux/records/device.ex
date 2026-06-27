defmodule Pux.Records.Device do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "devices" do
    field :push_token, :string
    field :platform, Ecto.Enum, values: [:fcm, :apns]
    field :last_seen_at, :utc_datetime_usec

    belongs_to :record, Pux.Records.Record, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:push_token, :platform, :last_seen_at, :record_id])
    |> validate_required([:push_token, :platform, :last_seen_at, :record_id])
    |> validate_length(:push_token, min: 8, max: 4096)
    |> unique_constraint([:record_id, :push_token])
  end
end
