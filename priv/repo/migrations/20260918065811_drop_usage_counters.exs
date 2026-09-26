defmodule Keeplix.Repo.Migrations.DropUsageCounters do
  use Ecto.Migration

  # Superseded by exact SUM/COUNT aggregates over the objects table
  # (no drift, version-aware). See Buckets.usage/1.
  def change do
    alter table(:buckets) do
      remove :usage_bytes
      remove :object_count
    end
  end
end
