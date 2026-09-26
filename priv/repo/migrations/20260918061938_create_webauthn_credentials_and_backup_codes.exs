defmodule Keeplix.Repo.Migrations.CreateWebauthnCredentialsAndBackupCodes do
  use Ecto.Migration

  def change do
    create table(:webauthn_credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :label, :string, null: false, default: "passkey"
      # base64url-encoded credential id, globally unique (Wax requirement).
      add :credential_id, :string, null: false
      # base64-encoded :erlang.term_to_binary of the COSE key map.
      add :public_key, :text, null: false
      add :sign_count, :integer, null: false, default: 0
      add :aaguid, :string
      add :last_used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:webauthn_credentials, [:credential_id])
    create index(:webauthn_credentials, [:user_id])

    create table(:backup_codes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :code_hash, :string, null: false
      add :used_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:backup_codes, [:user_id])
  end
end
