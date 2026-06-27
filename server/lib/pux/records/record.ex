defmodule Pux.Records.Record do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "records" do
    field :inbox_token, :string
    field :public_key, :binary
    field :last_active_at, :utc_datetime_usec

    has_many :devices, Pux.Records.Device

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:inbox_token, :public_key, :last_active_at])
    |> validate_required([:inbox_token, :public_key, :last_active_at])
    |> validate_length(:inbox_token, min: 8, max: 64)
    |> unique_constraint(:inbox_token)
  end
end
