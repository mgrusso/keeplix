defmodule Keeplix.EncryptedKeysTest do
  @moduledoc """
  S3 secrets rest encrypted; legacy plaintext rows upgrade on first use (P1).
  """
  use Keeplix.DataCase

  alias Keeplix.{Accounts, Repo, Vault}
  alias Keeplix.Accounts.AccessKey

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "enc-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    {:ok, user: user}
  end

  test "new keys store ciphertext only", %{user: user} do
    {:ok, record, %{secret: secret}} = Accounts.create_access_key(user, "enc")

    stored = Repo.get!(AccessKey, record.id)
    assert stored.secret == nil
    assert is_binary(stored.secret_enc)
    assert {:ok, ^secret} = Vault.decrypt(stored.secret_enc)
    assert {:ok, ^secret} = Accounts.key_secret(stored)
  end

  test "legacy plaintext rows upgrade transparently", %{user: user} do
    legacy =
      %AccessKey{}
      |> Ecto.Changeset.change(%{
        access_key_id: "FSLEGACY#{System.unique_integer([:positive])}",
        secret: "legacy-plaintext",
        user_id: user.id,
        active: true
      })
      |> Repo.insert!()

    assert {:ok, "legacy-plaintext"} = Accounts.key_secret(legacy)

    upgraded = Repo.get!(AccessKey, legacy.id)
    assert upgraded.secret == nil
    assert {:ok, "legacy-plaintext"} = Vault.decrypt(upgraded.secret_enc)
  end

  test "undecryptable rows fail closed", %{user: user} do
    broken =
      %AccessKey{}
      |> Ecto.Changeset.change(%{
        access_key_id: "FSBROKEN#{System.unique_integer([:positive])}",
        secret_enc: "v1:bm90LXZhbGlk",
        user_id: user.id,
        active: true
      })
      |> Repo.insert!()

    assert :error = Accounts.key_secret(broken)
  end
end
