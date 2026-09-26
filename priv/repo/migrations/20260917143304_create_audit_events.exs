defmodule Keeplix.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events) do
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :actor_username, :string
      add :action, :string, null: false
      add :target, :string
      add :meta, :text
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_events, [:inserted_at])
  end
end
