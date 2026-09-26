defmodule Keeplix.Repo.Migrations.AddVersionsToObjects do
  use Ecto.Migration

  # Existing rows become the single "null" version (S3 unversioned default).
  def change do
    alter table(:objects) do
      add :version_id, :string, null: false, default: "null"
      add :is_latest, :boolean, null: false, default: true
      add :deleted, :boolean, null: false, default: false
    end

    drop unique_index(:objects, [:bucket_id, :key])
    create unique_index(:objects, [:bucket_id, :key, :version_id])
    create index(:objects, [:bucket_id, :key, :is_latest])
  end
end
