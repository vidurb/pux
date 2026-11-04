defmodule Pux.Repo.Migrations.AddTokenCheckedAtToDevices do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add :token_checked_at, :utc_datetime_usec
    end
  end
end
