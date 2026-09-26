defmodule Keeplix.Repo.Migrations.AddVersioningToBuckets do
  use Ecto.Migration

  def change do
    alter table(:buckets) do
      add :versioning, :string, null: false, default: "off"
    end
  end
end
