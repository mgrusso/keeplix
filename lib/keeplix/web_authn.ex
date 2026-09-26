defmodule Keeplix.WebAuthn do
  @moduledoc """
  Passkeys (WebAuthn/FIDO2) as an optional second factor, plus one-time
  backup codes.

  Crypto verification is delegated to `Wax`; this context owns key
  storage, backup codes, and the login-step decision. A second step is
  required iff the user has at least one registered credential; backup
  codes are accepted as an alternative at that step. OIDC logins bypass
  local 2FA (the IdP authenticates).
  """
  import Ecto.Query

  alias Keeplix.Accounts.User
  alias Keeplix.Repo
  alias Keeplix.WebAuthn.{BackupCode, Credential}

  @backup_code_count 10

  # ---------- relying party ----------

  @spec base_url() :: String.t()
  def base_url do
    uri = KeeplixWeb.Endpoint.url() |> URI.parse()

    case uri.port do
      port when port in [80, 443, nil] -> "#{uri.scheme}://#{uri.host}"
      port -> "#{uri.scheme}://#{uri.host}:#{port}"
    end
  end

  @spec rp_id() :: String.t()
  def rp_id, do: URI.parse(base_url()).host || "localhost"

  @spec origin() :: String.t()
  def origin, do: base_url()

  @spec second_factor_required?(User.t()) :: boolean()
  def second_factor_required?(%User{id: uid}) do
    Repo.exists?(from c in Credential, where: c.user_id == ^uid)
  end

  # ---------- registration ----------

  @spec registration_challenge() :: Wax.Challenge.t()
  def registration_challenge do
    Wax.new_registration_challenge(
      origin: origin(),
      rp_id: rp_id(),
      attestation: "none",
      user_verification: "preferred"
    )
  end

  @spec verify_registration(User.t(), String.t() | nil, String.t(), String.t(), Wax.Challenge.t()) ::
          {:ok, Credential.t()} | {:error, term()}
  def verify_registration(
        %User{} = user,
        label,
        attestation_b64,
        client_data_json,
        %Wax.Challenge{} = challenge
      )
      when is_binary(client_data_json) do
    with {:ok, attestation} <- b64url_decode(attestation_b64),
         {:ok, {auth_data, _attestation}} <-
           Wax.register(attestation, client_data_json, challenge),
         %{credential_id: raw_id, credential_public_key: cose_key} <-
           auth_data.attested_credential_data || {:error, :missing_credential},
         true <- is_binary(raw_id) and byte_size(raw_id) > 0 and is_map(cose_key),
         credential_id = Base.url_encode64(raw_id, padding: false),
         false <- credential_taken?(credential_id) do
      %Credential{user_id: user.id}
      |> Credential.changeset(%{
        label: label_label(label),
        credential_id: credential_id,
        public_key: encode_key(cose_key),
        sign_count: auth_data.sign_count || 0,
        aaguid: format_aaguid(auth_data.attested_credential_data.aaguid)
      })
      |> Repo.insert()
    else
      true -> {:error, :already_registered}
      false -> {:error, :invalid_credential}
      {:error, _} = err -> err
      :error -> {:error, :invalid_encoding}
    end
  end

  def verify_registration(_, _, _, _, _), do: {:error, :invalid_encoding}

  defp label_label(nil), do: "passkey"
  defp label_label(""), do: "passkey"

  defp label_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.slice(0, 64)
    |> then(fn s -> if s == "", do: "passkey", else: s end)
  end

  defp label_label(_), do: "passkey"

  defp credential_taken?(credential_id) do
    Repo.exists?(from c in Credential, where: c.credential_id == ^credential_id)
  end

  defp format_aaguid(<<aaguid::binary-16>>), do: Base.encode16(aaguid, case: :lower)
  defp format_aaguid(_), do: nil

  defp encode_key(cose_key) when is_map(cose_key) do
    cose_key |> :erlang.term_to_binary() |> Base.encode64()
  end

  defp decode_key(%Credential{public_key: encoded}) do
    with {:ok, bin} <- Base.decode64(encoded),
         key when is_map(key) <- :erlang.binary_to_term(bin, [:safe]) do
      {:ok, key}
    else
      _ -> :error
    end
  end

  # ---------- authentication ----------

  @spec authentication_challenge(User.t()) :: Wax.Challenge.t()
  def authentication_challenge(%User{} = user) do
    Wax.new_authentication_challenge(
      origin: origin(),
      rp_id: rp_id(),
      user_verification: "preferred",
      allow_credentials: allow_credentials(user)
    )
  end

  defp allow_credentials(%User{id: uid}) do
    Repo.all(from c in Credential, where: c.user_id == ^uid)
    |> Enum.flat_map(fn cred ->
      case decode_key(cred) do
        {:ok, key} -> [{cred.credential_id, key}]
        :error -> []
      end
    end)
  end

  @spec verify_authentication(
          User.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          Wax.Challenge.t()
        ) ::
          {:ok, User.t()} | {:error, term()}
  def verify_authentication(
        %User{} = user,
        raw_id,
        auth_b64,
        sig_b64,
        client_data_json,
        %Wax.Challenge{} = challenge
      )
      when is_binary(raw_id) and is_binary(client_data_json) do
    with {:ok, auth_bin} <- b64url_decode(auth_b64),
         {:ok, sig} <- b64url_decode(sig_b64),
         {:ok, auth_data} <-
           Wax.authenticate(
             raw_id,
             auth_bin,
             sig,
             client_data_json,
             challenge,
             allow_credentials(user)
           ),
         {:ok, cred} <- fetch_credential(user.id, raw_id),
         :ok <- check_sign_count(cred, auth_data.sign_count) do
      touch_credential(cred, auth_data.sign_count)
      {:ok, user}
    else
      {:error, _} = err -> err
      :error -> {:error, :invalid_encoding}
    end
  end

  def verify_authentication(_, _, _, _, _, _), do: {:error, :invalid_encoding}

  defp fetch_credential(user_id, credential_id) do
    case Repo.get_by(Credential, user_id: user_id, credential_id: credential_id) do
      nil -> {:error, :unknown_credential}
      cred -> {:ok, cred}
    end
  end

  # Clone detection: authenticators increment per signature (0 = untracked).
  defp check_sign_count(%Credential{sign_count: stored}, new)
       when is_integer(new) and new > 0 and stored > 0 and new <= stored do
    {:error, :possible_clone}
  end

  defp check_sign_count(_, _), do: :ok

  defp touch_credential(%Credential{} = cred, sign_count) do
    cred
    |> Credential.changeset(%{
      sign_count: max(cred.sign_count, sign_count || 0),
      last_used_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  # ---------- credential management ----------

  @spec list_credentials(User.t()) :: [Credential.t()]
  def list_credentials(%User{id: uid}) do
    Repo.all(from c in Credential, where: c.user_id == ^uid, order_by: [desc: c.inserted_at])
  end

  @spec rename_credential(User.t(), integer(), String.t()) ::
          {:ok, Credential.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def rename_credential(%User{id: uid}, id, label) do
    with %Credential{} = cred <- Repo.get_by(Credential, id: id, user_id: uid) do
      cred |> Credential.changeset(%{label: label_label(label)}) |> Repo.update()
    else
      _ -> {:error, :not_found}
    end
  end

  @spec delete_credential(User.t(), integer()) :: {:ok, Credential.t()} | {:error, :not_found}
  def delete_credential(%User{id: uid}, id) do
    case Repo.get_by(Credential, id: id, user_id: uid) do
      nil -> {:error, :not_found}
      cred -> Repo.delete(cred)
    end
  end

  @doc """
  Removes all second-factor material (admin recovery when a user loses
  every authenticator and all backup codes).
  """
  @spec reset_2fa(User.t()) :: :ok
  def reset_2fa(%User{id: uid}) do
    Repo.delete_all(from c in Credential, where: c.user_id == ^uid)
    Repo.delete_all(from c in BackupCode, where: c.user_id == ^uid)
    :ok
  end

  # ---------- backup codes ----------

  @spec generate_backup_codes(User.t()) :: {:ok, [String.t()]} | {:error, term()}
  def generate_backup_codes(%User{} = user) do
    codes = for _ <- 1..@backup_code_count, do: random_code()

    Repo.transaction(fn ->
      Repo.delete_all(from c in BackupCode, where: c.user_id == ^user.id)

      Enum.each(codes, fn code ->
        %BackupCode{user_id: user.id}
        |> BackupCode.changeset(%{code_hash: Bcrypt.hash_pwd_salt(code)})
        |> Repo.insert!()
      end)

      codes
    end)
  end

  @spec verify_backup_code(User.t(), String.t()) :: {:ok, :used} | {:error, :invalid_code}
  def verify_backup_code(%User{} = user, code) when is_binary(code) do
    code = String.trim(code)

    unused =
      Repo.all(from c in BackupCode, where: c.user_id == ^user.id and is_nil(c.used_at))

    Enum.find_value(unused, {:error, :invalid_code}, fn record ->
      if Bcrypt.verify_pass(code, record.code_hash) do
        record |> Ecto.Changeset.change(used_at: DateTime.utc_now(:second)) |> Repo.update!()
        {:ok, :used}
      end
    end)
  end

  def verify_backup_code(_, _), do: {:error, :invalid_code}

  @spec remaining_backup_codes(User.t()) :: non_neg_integer()
  def remaining_backup_codes(%User{id: uid}) do
    Repo.aggregate(from(c in BackupCode, where: c.user_id == ^uid and is_nil(c.used_at)), :count)
  end

  defp random_code do
    alphabet = ~c"abcdefghjkmnpqrstuvwxyz23456789"
    raw = for _ <- 1..8, into: "", do: <<Enum.random(alphabet)>>
    <<a::binary-4, b::binary-4>> = raw
    a <> "-" <> b
  end

  # ---------- encoding helpers ----------

  defp b64url_decode(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> :error
    end
  end

  defp b64url_decode(_), do: :error
end
