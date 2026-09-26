defmodule Keeplix.Vault do
  @moduledoc """
  At-rest encryption for S3 access-key secrets (AES-256-GCM, random 96-bit
  nonce per value, versioned envelope `"v1:" <> base64(nonce <> tag <> ct)`).

  The data key comes from app config and must be 32 random bytes, base64
  encoded:

      config :keeplix, Keeplix.Vault,
        key: System.get_env("ACCESS_KEY_ENCRYPTION_KEY") # base64, 32 bytes

  In dev/test a committed fallback key is configured; **production refuses
  to boot without `ACCESS_KEY_ENCRYPTION_KEY`** (see `config/runtime.exs`).
  Rotate by deploying a new key and running `mix keeplix.reencrypt_keys`
  (re-encrypts every row with the new key).
  """

  @prefix "v1:"
  @nonce_bytes 12
  @tag_bytes 16

  @spec encrypt(String.t()) :: String.t()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@nonce_bytes)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key!(), iv, plaintext, "", true)
    @prefix <> Base.encode64(iv <> tag <> ct)
  end

  @spec decrypt(String.t() | nil) :: {:ok, String.t()} | :error
  def decrypt(ciphertext), do: do_decrypt(ciphertext, key!())

  @doc """
  Decrypts with an explicitly given base64 key (used for key rotation:
  old ciphertexts are unreadable with the new key).
  """
  @spec decrypt_with(String.t() | nil, String.t() | nil) :: {:ok, String.t()} | :error
  def decrypt_with(ciphertext, b64_key) do
    case decode_key(b64_key) do
      {:ok, key} -> do_decrypt(ciphertext, key)
      :error -> :error
    end
  end

  @spec configured?() :: boolean()
  def configured? do
    match?({:ok, _}, fetch_key())
  end

  # ---------- internals ----------

  defp do_decrypt(@prefix <> b64, key) do
    with {:ok, bin} <- Base.decode64(b64),
         <<iv::binary-@nonce_bytes, tag::binary-@tag_bytes, ct::binary>> <- bin,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, "", tag, false) do
      {:ok, plaintext}
    else
      _ -> :error
    end
  end

  defp do_decrypt(_, _), do: :error

  defp key! do
    case fetch_key() do
      {:ok, key} -> key
      :error -> raise "Keeplix.Vault: missing or invalid key (base64, 32 bytes)"
    end
  end

  defp fetch_key do
    decode_key(Application.get_env(:keeplix, __MODULE__, [])[:key])
  end

  defp decode_key(b64) when is_binary(b64) do
    with {:ok, key} <- Base.decode64(b64),
         true <- byte_size(key) == 32 do
      {:ok, key}
    else
      _ -> :error
    end
  end

  defp decode_key(_), do: :error
end
