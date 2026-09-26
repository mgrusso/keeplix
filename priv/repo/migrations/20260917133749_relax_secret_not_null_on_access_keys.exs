defmodule Keeplix.Repo.Migrations.RelaxSecretNotNullOnAccessKeys do
  use Ecto.Migration

  # SQLite cannot ALTER COLUMN nullability, so the table is rebuilt.
  # Afterwards `secret` is nullable: new rows store only `secret_enc`,
  # legacy plaintext is cleared on first use (see Accounts.key_secret/1).

  @columns ~w(id access_key_id secret description active user_id last_used_at inserted_at updated_at secret_enc)
  @column_list Enum.join(@columns, ", ")

  def up do
    execute("""
    CREATE TABLE access_keys_new (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "access_key_id" TEXT NOT NULL,
      "secret" TEXT,
      "description" TEXT,
      "active" INTEGER DEFAULT true NOT NULL,
      "user_id" INTEGER NOT NULL CONSTRAINT "access_keys_user_id_fkey" REFERENCES "users"("id") ON DELETE CASCADE,
      "last_used_at" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      "secret_enc" TEXT
    )
    """)

    execute(
      "INSERT INTO access_keys_new (#{@column_list}) SELECT #{@column_list} FROM access_keys"
    )

    execute("DROP TABLE access_keys")
    execute("ALTER TABLE access_keys_new RENAME TO access_keys")

    execute(
      "CREATE UNIQUE INDEX \"access_keys_access_key_id_index\" ON \"access_keys\" (\"access_key_id\")"
    )
  end

  def down do
    execute("UPDATE access_keys SET secret = '' WHERE secret IS NULL")

    execute("""
    CREATE TABLE access_keys_old (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "access_key_id" TEXT NOT NULL,
      "secret" TEXT NOT NULL,
      "description" TEXT,
      "active" INTEGER DEFAULT true NOT NULL,
      "user_id" INTEGER NOT NULL CONSTRAINT "access_keys_user_id_fkey" REFERENCES "users"("id") ON DELETE CASCADE,
      "last_used_at" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      "secret_enc" TEXT
    )
    """)

    execute(
      "INSERT INTO access_keys_old (#{@column_list}) SELECT #{@column_list} FROM access_keys"
    )

    execute("DROP TABLE access_keys")
    execute("ALTER TABLE access_keys_old RENAME TO access_keys")

    execute(
      "CREATE UNIQUE INDEX \"access_keys_access_key_id_index\" ON \"access_keys\" (\"access_key_id\")"
    )
  end
end
