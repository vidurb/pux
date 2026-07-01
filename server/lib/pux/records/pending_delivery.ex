defmodule Pux.Records.PendingDelivery do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "pending_deliveries" do
    field :envelope, :map

    belongs_to :record, Pux.Records.Record, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(pending_delivery, attrs) do
    pending_delivery
    |> cast(attrs, [:envelope, :record_id])
    |> validate_required([:envelope, :record_id])
  end
end
