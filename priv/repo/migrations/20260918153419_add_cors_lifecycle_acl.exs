defmodule Keeplix.Repo.Migrations.AddCorsLifecycleAcl do
  use Ecto.Migration

  def change do
    alter table(:buckets) do
      add :cors, :text, null: false, default: ""
      add :lifecycle, :text, null: false, default: ""
      add :acl, :string, null: false, default: "private"
    end

    alter table(:objects) do
      add :acl, :string, null: false, default: "private"
    end
  end
end
