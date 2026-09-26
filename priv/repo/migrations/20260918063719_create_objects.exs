defmodule Keeplix.Repo.Migrations.CreateObjects do
  use Ecto.Migration

  # Object metadata moves from `.keeplix-meta` sidecars into the database.
  # File content stays on the filesystem (addressed by bucket + key).
  # Existing sidecars are migrated by `mix keeplix.backfill_objects`.
  def change do
    create table(:objects) do
      add :bucket_id, references(:buckets, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :size, :bigint, null: false, default: 0
      add :etag, :string, null: false, default: ""
      add :content_type, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:objects, [:bucket_id, :key])
  end
end
