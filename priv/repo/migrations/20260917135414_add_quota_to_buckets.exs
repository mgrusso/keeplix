defmodule Keeplix.Repo.Migrations.AddQuotaToBuckets do
  use Ecto.Migration

  def change do
    alter table(:buckets) do
      # Max total object bytes for the bucket; NULL means unlimited.
      add :quota_bytes, :bigint
    end
  end
end
