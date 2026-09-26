defmodule Keeplix.Repo.Migrations.AddSecretCiphertextToAccessKeys do
  use Ecto.Migration

  def change do
    alter table(:access_keys) do
      # AES-256-GCM ciphertext of the S3 secret (see Keeplix.Vault).
      # Legacy rows may still carry the plaintext `secret` until first use.
      add :secret_enc, :text
    end
  end
end
