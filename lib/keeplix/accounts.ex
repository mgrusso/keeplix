defmodule Keeplix.Accounts do
  @moduledoc """
  User, group, and access key management.
  """
  import Ecto.Query
  alias Keeplix.Repo
  alias Keeplix.Accounts.{User, Group, Membership, AccessKey, ApiToken}

  # ---------- Users ----------

  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(order_by(User, asc: :username))

  @spec count_admins() :: non_neg_integer()
  def count_admins do
    Repo.aggregate(from(u in User, where: u.role == "admin"), :count)
  end

  @spec get_user(integer()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @spec get_user!(integer()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @spec get_user_by_username(String.t()) :: User.t() | nil
  def get_user_by_username(username) do
    Repo.get_by(User, username: username)
  end

  @spec get_user_by_oidc_sub(String.t()) :: User.t() | nil
  def get_user_by_oidc_sub(sub) do
    Repo.get_by(User, oidc_sub: sub)
  end

  @spec change_user(User.t(), map()) :: Ecto.Changeset.t()
  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end

  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) do
    password = Map.get(attrs, "password", Map.get(attrs, :password))

    %User{}
    |> User.registration_changeset(attrs)
    |> maybe_breach_check(password)
    |> Repo.insert()
  end

  @spec update_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(%User{} = user, attrs) do
    pwd = Map.get(attrs, "password", Map.get(attrs, :password))

    if pwd in [nil, ""] do
      clean = Map.drop(Enum.into(attrs, %{}, fn {k, v} -> {to_string(k), v} end), ["password"])

      user
      |> User.changeset(clean)
      |> Repo.update()
    else
      user
      |> User.changeset(attrs)
      |> maybe_update_password(attrs)
      |> maybe_breach_check(pwd)
      |> Repo.update()
    end
  end

  defp maybe_breach_check(changeset, password) when is_binary(password) and password != "" do
    if changeset.valid? and Keeplix.PasswordBreach.breached?(password) do
      Ecto.Changeset.add_error(
        changeset,
        :password,
        "has appeared in a data breach, choose another one"
      )
    else
      changeset
    end
  end

  defp maybe_breach_check(changeset, _), do: changeset

  defp maybe_update_password(changeset, attrs) do
    pwd = Map.get(attrs, "password", Map.get(attrs, :password))

    if pwd in [nil, ""] do
      changeset
    else
      Ecto.Changeset.put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(pwd))
    end
  end

  @spec delete_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def delete_user(%User{} = user), do: Repo.delete(user)

  @doc """
  Resolves the initial admin password for seeds: the explicit
  `ADMIN_PASSWORD` value, or a generated one when unset. There is
  deliberately no default password.
  """
  @spec seed_admin_password() :: {:provided, String.t()} | {:generated, String.t()}
  def seed_admin_password do
    case System.get_env("ADMIN_PASSWORD") do
      pass when is_binary(pass) and pass != "" -> {:provided, pass}
      _ -> {:generated, Base.encode64(:crypto.strong_rand_bytes(18))}
    end
  end

  @spec authenticate(String.t(), String.t()) ::
          {:ok, User.t()}
          | {:error, :not_found | :inactive | :no_password | :invalid_password}
  def authenticate(username, password) do
    user = get_user_by_username(username)

    cond do
      user == nil -> {:error, :not_found}
      not user.is_active -> {:error, :inactive}
      user.password_hash == nil -> {:error, :no_password}
      Bcrypt.verify_pass(password, user.password_hash) -> {:ok, user}
      true -> {:error, :invalid_password}
    end
  end

  @doc """
  Lets a user change their own password. Users without a password
  (e.g. provisioned via OIDC) may set one without the current check.
  """
  @spec update_own_password(User.t(), map()) ::
          {:ok, User.t()}
          | {:error, :invalid_current | :mismatch | :too_short | :pwned | Ecto.Changeset.t()}
  def update_own_password(%User{} = user, attrs) do
    current = Map.get(attrs, "current_password", Map.get(attrs, :current_password))
    password = Map.get(attrs, "password", Map.get(attrs, :password))
    confirmation = Map.get(attrs, "password_confirmation", Map.get(attrs, :password_confirmation))

    current_ok? =
      is_nil(user.password_hash) or
        (is_binary(current) and Bcrypt.verify_pass(current, user.password_hash))

    cond do
      not current_ok? -> {:error, :invalid_current}
      not (is_binary(password) and password == confirmation) -> {:error, :mismatch}
      String.length(password) < 8 -> {:error, :too_short}
      Keeplix.PasswordBreach.breached?(password) -> {:error, :pwned}
      true -> user |> User.password_changeset(%{password: password}) |> Repo.update()
    end
  end

  @spec user_groups(User.t()) :: [Group.t()]
  def user_groups(%User{id: user_id}) do
    Repo.all(
      from g in Group,
        join: m in Membership,
        on: m.group_id == g.id,
        where: m.user_id == ^user_id
    )
  end

  @spec user_group_ids(User.t()) :: [integer()]
  def user_group_ids(%User{id: user_id}) do
    Repo.all(from m in Membership, where: m.user_id == ^user_id, select: m.group_id)
  end

  # ---------- Groups ----------

  @spec list_groups() :: [Group.t()]
  def list_groups, do: Repo.all(order_by(Group, asc: :name))
  @spec get_group!(integer()) :: Group.t()
  def get_group!(id), do: Repo.get!(Group, id) |> Repo.preload(:users)
  @spec get_group(integer()) :: Group.t() | nil
  def get_group(id), do: Repo.get(Group, id)

  @spec create_group(map()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def create_group(attrs) do
    %Group{} |> Group.changeset(attrs) |> Repo.insert()
  end

  @spec update_group(Group.t(), map()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def update_group(%Group{} = group, attrs) do
    group |> Group.changeset(attrs) |> Repo.update()
  end

  @spec delete_group(Group.t()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def delete_group(%Group{} = group), do: Repo.delete(group)

  @spec add_user_to_group(User.t(), Group.t()) ::
          {:ok, Membership.t()} | {:error, Ecto.Changeset.t()}
  def add_user_to_group(%User{id: uid}, %Group{id: gid}) do
    %Membership{user_id: uid, group_id: gid}
    |> Repo.insert(on_conflict: :nothing)
  end

  @spec remove_user_from_group(User.t(), Group.t()) :: :ok
  def remove_user_from_group(%User{id: uid}, %Group{id: gid}) do
    Repo.delete_all(from m in Membership, where: m.user_id == ^uid and m.group_id == ^gid)
    :ok
  end

  @spec group_members(Group.t()) :: [User.t()]
  def group_members(%Group{id: gid}) do
    Repo.all(
      from u in User, join: m in Membership, on: m.user_id == u.id, where: m.group_id == ^gid
    )
  end

  # ---------- Access keys ----------

  @spec list_keys_for_user(integer()) :: [AccessKey.t()]
  def list_keys_for_user(user_id) do
    Repo.all(from k in AccessKey, where: k.user_id == ^user_id, order_by: [desc: k.inserted_at])
  end

  @spec list_all_keys() :: [AccessKey.t()]
  def list_all_keys do
    Repo.all(from k in AccessKey, order_by: [desc: k.inserted_at]) |> Repo.preload(:user)
  end

  @spec get_access_key(integer()) :: AccessKey.t() | nil
  def get_access_key(id) when is_integer(id), do: Repo.get(AccessKey, id)
  def get_access_key(_), do: nil

  @spec get_access_key!(integer()) :: AccessKey.t()
  def get_access_key!(id), do: Repo.get!(AccessKey, id) |> Repo.preload(:user)

  @spec count_keys_for_user(integer()) :: non_neg_integer()
  def count_keys_for_user(user_id) do
    Repo.aggregate(from(k in AccessKey, where: k.user_id == ^user_id), :count)
  end

  @spec get_key_by_access_id(String.t()) :: AccessKey.t() | nil
  def get_key_by_access_id(access_key_id) do
    Repo.get_by(AccessKey, access_key_id: access_key_id) |> maybe_preload_user()
  end

  # ---------- API tokens (Personal Access Tokens) ----------

  @doc """
  Creates a personal access token for management API use. The plain
  token is returned once and only its SHA-256 hash is stored.
  """
  @spec create_api_token(User.t(), String.t(), keyword()) ::
          {:ok, ApiToken.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_api_token(%User{id: uid}, name, opts \\ []) do
    plain = "kp_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    hash = :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)

    attrs = %{
      name: name,
      token_hash: hash,
      prefix: String.slice(plain, 0, 12),
      expires_at: Keyword.get(opts, :expires_at)
    }

    case %ApiToken{}
         |> ApiToken.changeset(attrs)
         |> Ecto.Changeset.put_change(:user_id, uid)
         |> Repo.insert() do
      {:ok, record} -> {:ok, record, plain}
      error -> error
    end
  end

  @spec list_api_tokens(integer()) :: [ApiToken.t()]
  def list_api_tokens(user_id) do
    Repo.all(from t in ApiToken, where: t.user_id == ^user_id, order_by: [desc: t.inserted_at])
  end

  @spec revoke_api_token(User.t(), integer()) :: :ok | {:error, :not_found}
  def revoke_api_token(%User{id: uid}, token_id) do
    case Repo.get_by(ApiToken, id: token_id, user_id: uid) do
      nil -> {:error, :not_found}
      token -> Repo.delete(token) |> then(fn _ -> :ok end)
    end
  end

  @doc """
  Verifies a bearer token: known hash, active owner, unexpired.
  Touches last_used_at on success.
  """
  @spec verify_api_token(String.t()) :: {:ok, User.t()} | {:error, term()}
  def verify_api_token(plain) when is_binary(plain) do
    hash = :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)

    case Repo.get_by(ApiToken, token_hash: hash) |> maybe_preload_token_user() do
      %ApiToken{user: %User{is_active: true} = user} = token ->
        if expired?(token) do
          {:error, :expired}
        else
          token
          |> ApiToken.changeset(%{last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)})
          |> Repo.update!()

          {:ok, user}
        end

      _ ->
        {:error, :unknown_token}
    end
  end

  def verify_api_token(_), do: {:error, :unknown_token}

  defp maybe_preload_token_user(nil), do: nil
  defp maybe_preload_token_user(token), do: Repo.preload(token, :user)

  defp expired?(%ApiToken{expires_at: nil}), do: false

  defp expired?(%ApiToken{expires_at: exp}) do
    DateTime.compare(DateTime.utc_now(), exp) != :lt
  end

  defp maybe_preload_user(nil), do: nil
  defp maybe_preload_user(key), do: Repo.preload(key, :user)

  @spec create_access_key(User.t(), String.t() | nil) ::
          {:ok, AccessKey.t(), %{access_key_id: String.t(), secret: String.t()}}
          | {:error, Ecto.Changeset.t()}
  def create_access_key(%User{id: uid}, description \\ nil) do
    access_id = generate_access_id()
    secret = generate_secret()

    attrs = %{
      access_key_id: access_id,
      secret_enc: Keeplix.Vault.encrypt(secret),
      secret: nil,
      description: description,
      active: true
    }

    case %AccessKey{}
         |> AccessKey.changeset(attrs)
         |> Ecto.Changeset.put_change(:user_id, uid)
         |> Repo.insert() do
      {:ok, record} ->
        {:ok, %{record | secret: secret}, %{access_key_id: access_id, secret: secret}}

      error ->
        error
    end
  end

  @doc """
  Resolves the plaintext S3 secret for a key row.

  Decrypts `:secret_enc`; legacy rows carrying only the plaintext `:secret`
  are re-encrypted transparently on first use.
  """
  @spec key_secret(AccessKey.t()) :: {:ok, String.t()} | :error
  def key_secret(%AccessKey{secret_enc: enc} = key) do
    case Keeplix.Vault.decrypt(enc) do
      {:ok, secret} ->
        {:ok, secret}

      :error when is_binary(key.secret) ->
        upgrade_legacy_secret(key)

      :error ->
        :error
    end
  end

  defp upgrade_legacy_secret(%AccessKey{} = key) do
    # Best effort: even if the upgrade write fails, the secret itself is valid.
    _ =
      key
      |> Ecto.Changeset.change(secret_enc: Keeplix.Vault.encrypt(key.secret), secret: nil)
      |> Repo.update()

    {:ok, key.secret}
  end

  @spec delete_access_key(integer()) :: {:ok, AccessKey.t()} | {:error, :not_found}
  def delete_access_key(id) do
    case Repo.get(AccessKey, id) do
      nil -> {:error, :not_found}
      key -> Repo.delete(key)
    end
  end

  @spec set_key_active(AccessKey.t(), boolean()) ::
          {:ok, AccessKey.t()} | {:error, Ecto.Changeset.t()}
  def set_key_active(%AccessKey{} = key, active) do
    key |> Ecto.Changeset.change(active: active) |> Repo.update()
  end

  @spec touch_key_used(AccessKey.t()) :: {:ok, AccessKey.t()} | {:error, Ecto.Changeset.t()}
  def touch_key_used(%AccessKey{} = key) do
    key |> Ecto.Changeset.change(last_used_at: DateTime.utc_now(:second)) |> Repo.update()
  end

  defp generate_access_id do
    "KB" <> Base.encode32(:crypto.strong_rand_bytes(12), case: :upper, padding: false)
  end

  defp generate_secret do
    Base.encode64(:crypto.strong_rand_bytes(30), padding: false)
  end

  # ---------- OIDC ----------

  @spec upsert_oidc_user(%{
          sub: String.t(),
          preferred_username: String.t() | nil,
          email: String.t() | nil,
          name: String.t() | nil,
          groups: [String.t()]
        }) :: {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  def upsert_oidc_user(
        %{sub: sub, preferred_username: username, email: email, name: name, groups: _oidc_groups} =
          claims
      )
      when is_binary(sub) and sub != "" do
    # Account linking is bound strictly to the IdP subject. A matching
    # local username alone NEVER links accounts (account-takeover risk).
    existing = get_user_by_oidc_sub(sub)
    groups = Map.get(claims, :groups, []) |> List.wrap()
    candidate_username = normalize_username(username || email || sub)

    cond do
      existing && not existing.is_active ->
        # Suspended users stay suspended: SSO must not reactivate them.
        {:error, :inactive}

      existing ->
        attrs = %{
          email: email || existing.email,
          display_name: name || existing.display_name,
          oidc_sub: sub
        }

        attrs =
          if promote_to_admin?(existing, groups), do: Map.put(attrs, :role, "admin"), else: attrs

        existing
        |> User.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, user} ->
            sync_oidc_groups(user, groups)
            {:ok, user}

          error ->
            error
        end

      username_taken?(candidate_username) ->
        {:error, :username_taken}

      true ->
        role = if new_oidc_admin?(groups), do: "admin", else: "user"

        %User{}
        |> User.changeset(%{
          username: candidate_username,
          email: email,
          display_name: name,
          oidc_sub: sub,
          role: role,
          is_active: true
        })
        |> Ecto.Changeset.put_change(:password_hash, nil)
        |> Repo.insert()
        |> case do
          {:ok, user} ->
            sync_oidc_groups(user, groups)
            {:ok, user}

          error ->
            error
        end
    end
  end

  def upsert_oidc_user(_claims), do: {:error, :invalid_claims}

  defp username_taken?(username) do
    is_binary(username) and not is_nil(get_user_by_username(username))
  end

  # First user becomes admin only with explicit opt-in (bootstrap race);
  # members of the configured admin groups are promoted (never demoted).
  defp new_oidc_admin?(groups) do
    (Keeplix.Oidc.first_admin?() and Repo.aggregate(User, :count) == 0) or
      in_admin_groups?(groups)
  end

  defp promote_to_admin?(%User{role: "admin"}, _groups), do: false
  defp promote_to_admin?(_user, groups), do: in_admin_groups?(groups)

  defp in_admin_groups?(groups) do
    admin_groups = Keeplix.Oidc.admin_groups()
    admin_groups != [] and Enum.any?(groups, &(&1 in admin_groups))
  end

  defp normalize_username(s) do
    s |> String.downcase() |> String.replace(~r/[^a-z0-9._-]/, "-") |> String.slice(0, 64)
  end

  # Group memberships are synced additively on every login (not just on
  # signup). Revoking memberships stays a manual admin task, so a changed
  # IdP claim can never lock users out of locally granted access.
  defp sync_oidc_groups(_user, []), do: :ok

  defp sync_oidc_groups(user, group_names) when is_list(group_names) do
    Enum.each(group_names, fn gname ->
      group =
        case Repo.get_by(Group, name: gname) do
          nil ->
            case create_group(%{name: gname, description: "via OIDC"}) do
              {:ok, g} -> g
              {:error, _} -> Repo.get_by(Group, name: gname)
            end

          g ->
            g
        end

      if group, do: add_user_to_group(user, group)
    end)
  end
end
