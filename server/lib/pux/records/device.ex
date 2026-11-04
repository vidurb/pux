defmodule Pux.Records.Device do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "devices" do
    # `redact` keeps these out of inspect/1, and so out of error logs and crash reports.
    field :push_token, :string, redact: true
    field :record_id, :binary_id, redact: true
    field :platform, Ecto.Enum, values: [:fcm, :apns, :desktop]
    # Registration or an accepted push. Age limits run from this.
    field :last_seen_at, :utc_datetime_usec
    # The last dry-run check that passed. Says nothing about the device being used, so it
    # only spaces out checks and never extends an age limit.
    field :token_checked_at, :utc_datetime_usec

    belongs_to :record, Pux.Records.Record, define_field: false

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
