defmodule Keeplix.Repo.Migrations.AddTrashToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :trashed, :boolean, null: false, default: false
      add :trashed_at, :utc_datetime
    end

    create index(:objects, [:bucket_id, :trashed])
  end
end
