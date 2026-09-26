defmodule Keeplix.Repo.Migrations.CreateKeeplixCore do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :email, :string
      add :password_hash, :string
      add :role, :string, null: false, default: "user"
      add :display_name, :string
      add :is_active, :boolean, null: false, default: true
      add :oidc_sub, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:oidc_sub])

    create table(:groups) do
      add :name, :string, null: false
      add :description, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:name])

    create table(:group_memberships) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:group_memberships, [:user_id, :group_id])

    create table(:access_keys) do
      add :access_key_id, :string, null: false
      add :secret, :string, null: false
      add :description, :string
      add :active, :boolean, null: false, default: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :last_used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:access_keys, [:access_key_id])

    create table(:buckets) do
      add :name, :string, null: false
      add :owner_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:buckets, [:name])

    create table(:bucket_grants) do
      add :bucket_id, references(:buckets, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :group_id, references(:groups, on_delete: :delete_all)
      add :permission, :string, null: false, default: "read"
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:bucket_grants, [:bucket_id])
    create unique_index(:bucket_grants, [:bucket_id, :user_id, :group_id, :permission])
  end
end
