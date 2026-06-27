defmodule Pux.Repo.Migrations.CreateRecordsAndDevices do
  use Ecto.Migration

  def change do
    create table(:records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :inbox_token, :string, null: false
      add :public_key, :binary, null: false
      add :last_active_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:records, [:inbox_token])

    create table(:devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :record_id, references(:records, type: :binary_id, on_delete: :delete_all), null: false
      add :push_token, :text, null: false
      add :platform, :string, null: false
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:devices, [:record_id, :push_token])
    create index(:devices, [:record_id])
    create index(:records, [:last_active_at])
    create index(:devices, [:last_seen_at])
  end
end
