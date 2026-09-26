defmodule Keeplix.Repo.Migrations.AddUsageCountersToBuckets do
  use Ecto.Migration

  # Denormalized usage ledger (see Buckets.adjust_usage/3). Existing rows
  # start at zero; run `mix keeplix.rescan_usage` once to backfill them.
  def change do
    alter table(:buckets) do
      add :usage_bytes, :bigint, default: 0, null: false
      add :object_count, :integer, default: 0, null: false
    end
  end
end
