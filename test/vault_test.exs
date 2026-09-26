defmodule Keeplix.VaultTest do
  @moduledoc """
  At-rest encryption for S3 secrets (P1).
  """
  use ExUnit.Case, async: true

  alias Keeplix.Vault

  test "encrypt/decrypt roundtrip" do
    ct = Vault.encrypt("super-secret")
    assert ct != "super-secret"
    assert String.starts_with?(ct, "v1:")
    assert {:ok, "super-secret"} = Vault.decrypt(ct)
  end

  test "ciphertexts are randomized" do
    assert Vault.encrypt("same") != Vault.encrypt("same")
  end

  test "tampered ciphertexts are rejected" do
    "v1:" <> b64 = Vault.encrypt("super-secret")
    {:ok, bin} = Base.decode64(b64)
    <<head::binary-20, last::binary-1, _::binary>> = bin
    flipped = if last == "A", do: "B", else: "A"
    assert :error = Vault.decrypt("v1:" <> Base.encode64(head <> flipped <> "X"))
  end

  test "garbage and nil are rejected" do
    assert :error = Vault.decrypt(nil)
    assert :error = Vault.decrypt("")
    assert :error = Vault.decrypt("v1:!!!not-base64!!!")
    assert :error = Vault.decrypt("plaintext-secret")
  end

  test "decrypt_with/2 honors the given key" do
    ct = Vault.encrypt("super-secret")
    other = Base.encode64(:crypto.strong_rand_bytes(32))
    assert :error = Vault.decrypt_with(ct, other)
    assert :error = Vault.decrypt_with(ct, "not-a-key")
  end
end
