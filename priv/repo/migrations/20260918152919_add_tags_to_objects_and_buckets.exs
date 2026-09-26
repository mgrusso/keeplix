defmodule Keeplix.Repo.Migrations.AddTagsToObjectsAndBuckets do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :tags, :text, null: false, default: "{}"
    end

    alter table(:buckets) do
      add :tag_set, :text, null: false, default: "{}"
    end
  end
end
