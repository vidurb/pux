defmodule Pux.Repo.Migrations.AddPendingDeliveries do
  use Ecto.Migration

  def change do
    create table(:pending_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :record_id, references(:records, type: :binary_id, on_delete: :delete_all), null: false
      add :envelope, :map, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:pending_deliveries, [:record_id])
    create index(:pending_deliveries, [:inserted_at])
  end
end
