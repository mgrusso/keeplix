defmodule Mix.Tasks.Keeplix.ReencryptKeys do
  @shortdoc "Re-encrypts S3 access-key secrets with the current Vault key"

  @moduledoc """
  Re-encrypts every access-key secret with the currently configured
  `Keeplix.Vault` key and clears legacy plaintext secrets.

  Key rotation procedure:

      OLD_ACCESS_KEY_ENCRYPTION_KEY=<old key> \\
        mix keeplix.reencrypt_keys

  Rows already encrypted with the current key (or holding only legacy
  plaintext) are handled automatically; unreadable rows are reported
  and left untouched.
  """
  use Mix.Task

  alias Keeplix.Repo
  alias Keeplix.Accounts.AccessKey
  alias Keeplix.Vault

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [old_key: :string])
    Mix.Task.run("app.start")

    old_key = opts[:old_key] || System.get_env("OLD_ACCESS_KEY_ENCRYPTION_KEY")

    unless Vault.configured?() do
      Mix.raise("Keeplix.Vault key is not configured")
    end

    {current, legacy, failed} =
      Repo.all(AccessKey)
      |> Enum.reduce({0, 0, 0}, fn key, {c, l, f} ->
        case reencrypt(key, old_key) do
          :current -> {c + 1, l, f}
          :legacy -> {c, l + 1, f}
          :failed -> {c, l, f + 1}
        end
      end)

    Mix.shell().info("reencrypt_keys: #{current} current, #{legacy} upgraded, #{failed} failed")
  end

  defp reencrypt(%AccessKey{secret_enc: enc} = key, old_key) when is_binary(enc) do
    cond do
      match?({:ok, _}, Vault.decrypt(enc)) ->
        :current

      is_binary(old_key) and match?({:ok, _}, Vault.decrypt_with(enc, old_key)) ->
        {:ok, secret} = Vault.decrypt_with(enc, old_key)
        store(key, secret)

      is_binary(key.secret) ->
        store(key, key.secret)

      true ->
        :failed
    end
  end

  defp reencrypt(%AccessKey{secret: secret} = key, _old_key) when is_binary(secret) do
    store(key, secret)
  end

  defp reencrypt(_, _), do: :failed

  defp store(key, secret) do
    key
    |> Ecto.Changeset.change(secret_enc: Vault.encrypt(secret), secret: nil)
    |> Repo.update()
    |> case do
      {:ok, _} -> :legacy
      {:error, _} -> :failed
    end
  end
end
