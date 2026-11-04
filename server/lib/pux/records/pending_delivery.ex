defmodule Pux.Records.PendingDelivery do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "pending_deliveries" do
    field :envelope, :map
    # `redact` keeps the credential out of inspect/1, and so out of logs and crash reports.
    field :record_id, :binary_id, redact: true

    belongs_to :record, Pux.Records.Record, define_field: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(pending_delivery, attrs) do
    pending_delivery
    |> cast(attrs, [:envelope, :record_id])
    |> validate_required([:envelope, :record_id])
    |> foreign_key_constraint(:record_id)
  end
end
