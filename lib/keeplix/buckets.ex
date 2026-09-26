defmodule Keeplix.Buckets do
  @moduledoc """
  Bucket management and grants (user / group -> read | write | admin).
  """
  import Ecto.Query
  alias Keeplix.Repo
  alias Keeplix.Buckets.{Bucket, Grant}
  alias Keeplix.Accounts.User
  alias Keeplix.Storage

  @spec list_buckets() :: [Bucket.t()]
  def list_buckets do
    Repo.all(order_by(Bucket, asc: :name)) |> Repo.preload(:owner)
  end

  @spec get_bucket(String.t()) :: Bucket.t() | nil
  def get_bucket(name), do: Repo.get_by(Bucket, name: name) |> preload_owner()
  @spec get_bucket!(integer()) :: Bucket.t()
  def get_bucket!(id), do: Repo.get!(Bucket, id) |> preload_owner()
  @spec get_bucket_by_id(integer()) :: Bucket.t() | nil
  def get_bucket_by_id(id) when is_integer(id), do: Repo.get(Bucket, id) |> preload_owner()
  def get_bucket_by_id(_), do: nil

  defp preload_owner(nil), do: nil
  defp preload_owner(b), do: Repo.preload(b, :owner)

  @spec change_bucket(Bucket.t(), map()) :: Ecto.Changeset.t()
  def change_bucket(%Bucket{} = b, attrs \\ %{}), do: Bucket.changeset(b, attrs)

  @spec update_bucket(Bucket.t(), map()) :: {:ok, Bucket.t()} | {:error, Ecto.Changeset.t()}
  def update_bucket(%Bucket{} = bucket, attrs) do
    bucket |> Bucket.changeset(attrs) |> Repo.update()
  end

  @doc """
  Bucket tag set (S3 Tagging), decoded from the stored JSON.
  """
  @spec get_bucket_tags(Bucket.t() | String.t()) :: %{String.t() => String.t()}
  def get_bucket_tags(%Bucket{tag_set: tag_set}), do: decode_tags(tag_set)

  def get_bucket_tags(name) when is_binary(name) do
    case get_bucket(name) do
      %Bucket{} = b -> get_bucket_tags(b)
      nil -> %{}
    end
  end

  @spec put_bucket_tags(Bucket.t(), map()) :: {:ok, Bucket.t()} | {:error, term()}
  def put_bucket_tags(%Bucket{} = bucket, tags) do
    with :ok <- Keeplix.Storage.validate_tags(tags) do
      update_bucket(bucket, %{tag_set: Jason.encode!(tags)})
    end
  end

  @spec delete_bucket_tags(Bucket.t()) :: {:ok, Bucket.t()} | {:error, term()}
  def delete_bucket_tags(%Bucket{} = bucket), do: update_bucket(bucket, %{tag_set: "{}"})

  @doc """
  CORS rules of a bucket, decoded (empty list when unconfigured).
  """
  @spec get_cors_config(Bucket.t() | String.t()) :: [map()]
  def get_cors_config(%Bucket{cors: cors}), do: decode_json_list(cors)

  def get_cors_config(name) when is_binary(name) do
    case get_bucket(name) do
      %Bucket{} = b -> get_cors_config(b)
      nil -> []
    end
  end

  @spec put_cors_config(Bucket.t(), [map()]) :: {:ok, Bucket.t()} | {:error, term()}
  def put_cors_config(%Bucket{} = bucket, rules) do
    update_bucket(bucket, %{cors: Jason.encode!(rules)})
  end

  @spec delete_cors_config(Bucket.t()) :: {:ok, Bucket.t()} | {:error, term()}
  def delete_cors_config(%Bucket{} = bucket), do: update_bucket(bucket, %{cors: ""})

  @doc """
  Lifecycle rules of a bucket, decoded (empty list when unconfigured).
  """
  @spec get_lifecycle_config(Bucket.t() | String.t()) :: [map()]
  def get_lifecycle_config(%Bucket{lifecycle: lifecycle}), do: decode_json_list(lifecycle)

  def get_lifecycle_config(name) when is_binary(name) do
    case get_bucket(name) do
      %Bucket{} = b -> get_lifecycle_config(b)
      nil -> []
    end
  end

  @spec put_lifecycle_config(Bucket.t(), [map()]) :: {:ok, Bucket.t()} | {:error, term()}
  def put_lifecycle_config(%Bucket{} = bucket, rules) do
    update_bucket(bucket, %{lifecycle: Jason.encode!(rules)})
  end

  @spec delete_lifecycle_config(Bucket.t()) :: {:ok, Bucket.t()} | {:error, term()}
  def delete_lifecycle_config(%Bucket{} = bucket), do: update_bucket(bucket, %{lifecycle: ""})

  @doc """
  Matches an Origin + method against the bucket CORS rules.
  Returns `{:ok, rule, origin}` (origin echoed, `*` stays literal unless
  the rule lists a single non-wildcard origin) or `:deny`.
  """
  @spec cors_allowed?(Bucket.t() | String.t(), String.t() | nil, String.t()) ::
          {:ok, map(), String.t()} | :deny
  def cors_allowed?(bucket, origin, method)

  def cors_allowed?(_bucket, nil, _method), do: :deny
  def cors_allowed?(_bucket, "", _method), do: :deny

  def cors_allowed?(bucket, origin, method) do
    method = method |> to_string() |> String.upcase()

    Enum.find_value(get_cors_config(bucket), :deny, fn rule ->
      if method in (rule["allowed_methods"] || []) and origin_allowed?(rule, origin) do
        {:ok, rule, origin}
      end
    end)
  end

  defp origin_allowed?(%{"allowed_origins" => ["*"]}, _origin), do: true

  defp origin_allowed?(%{"allowed_origins" => origins}, origin),
    do: Enum.any?(origins || [], &(&1 == origin))

  defp origin_allowed?(_, _), do: false

  defp decode_json_list(nil), do: []
  defp decode_json_list(""), do: []

  defp decode_json_list(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_tags(nil), do: %{}
  defp decode_tags(""), do: %{}

  defp decode_tags(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
      _ -> %{}
    end
  end

  @doc """
  Changes the versioning state. Like S3, states only move forward:
  `off` → `enabled`, either way between `enabled` and `suspended`,
  never back to `off` (old versions stay addressable).
  """
  @spec set_versioning(Bucket.t(), String.t()) :: {:ok, Bucket.t()} | {:error, term()}
  def set_versioning(%Bucket{versioning: current} = bucket, mode)
      when mode in ["off", "enabled", "suspended"] do
    allowed? =
      case {current, mode} do
        {same, same} -> true
        {"off", "enabled"} -> true
        {"enabled", "suspended"} -> true
        {"suspended", "enabled"} -> true
        _ -> false
      end

    if allowed? do
      update_bucket(bucket, %{versioning: mode})
    else
      {:error, :invalid_transition}
    end
  end

  def set_versioning(_, _), do: {:error, :invalid_transition}

  @doc """
  Exact usage from the objects table (all versions count, like S3
  billing). Indexed aggregates, no filesystem walk, no drift.
  """
  @spec usage(Bucket.t() | integer()) :: %{bytes: non_neg_integer(), count: non_neg_integer()}
  def usage(%Bucket{id: id}), do: usage(id)

  def usage(bucket_id) when is_integer(bucket_id) do
    alias Keeplix.Storage.Object

    bytes =
      Repo.aggregate(from(o in Object, where: o.bucket_id == ^bucket_id), :sum, :size) || 0

    count = Repo.aggregate(from(o in Object, where: o.bucket_id == ^bucket_id), :count)

    %{bytes: bytes, count: count}
  end

  @doc """
  Checks whether `additional_bytes` still fit into the bucket quota,
  using exact aggregates from the objects table.
  """
  @spec quota_allows?(Bucket.t(), non_neg_integer()) :: :ok | {:error, :quota_exceeded}
  def quota_allows?(%Bucket{quota_bytes: nil}, _additional), do: :ok

  def quota_allows?(%Bucket{id: id, quota_bytes: quota}, additional) do
    if usage(id).bytes + additional <= quota, do: :ok, else: {:error, :quota_exceeded}
  end

  @spec create_bucket(String.t(), User.t()) :: {:ok, Bucket.t()} | {:error, term()}
  def create_bucket(name, %User{id: owner_id} = _owner) do
    Repo.transaction(fn ->
      with {:ok, bucket} <-
             %Bucket{}
             |> Bucket.changeset(%{name: name})
             |> Ecto.Changeset.put_change(:owner_id, owner_id)
             |> Repo.insert(),
           :ok <- Storage.create_bucket(name),
           {:ok, _} <-
             %Grant{}
             |> Grant.changeset(%{bucket_id: bucket.id, user_id: owner_id, permission: "admin"})
             |> Repo.insert(on_conflict: :nothing) do
        Repo.preload(bucket, :owner)
      else
        {:error, cs} -> Repo.rollback(cs)
        {:error, _op, val, _} -> Repo.rollback(val)
        other -> Repo.rollback(other)
      end
    end)
    |> case do
      {:ok, bucket} -> {:ok, bucket}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete_bucket(Bucket.t()) :: :ok | {:error, term()}
  def delete_bucket(%Bucket{} = bucket) do
    Repo.transaction(fn ->
      with {:ok, _} <- Repo.delete(bucket),
           :ok <- Storage.delete_bucket(bucket.name) do
        :ok
      else
        {:error, cs} -> Repo.rollback(cs)
        other -> Repo.rollback(other)
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------- Grants ----------

  @spec list_grants(integer()) :: [Grant.t()]
  def list_grants(bucket_id) do
    Repo.all(from g in Grant, where: g.bucket_id == ^bucket_id)
    |> Repo.preload([:user, :group])
  end

  @spec grant_permission(integer(), String.t(), keyword() | map()) ::
          {:ok, Grant.t()} | {:error, Ecto.Changeset.t()}
  def grant_permission(bucket_id, permission, opts) do
    attrs =
      %{bucket_id: bucket_id, permission: permission}
      |> Map.merge(Map.new(opts))

    %Grant{} |> Grant.changeset(attrs) |> Repo.insert(on_conflict: :nothing)
  end

  @spec revoke_grant(integer()) :: {:ok, Grant.t()} | {:error, :not_found}
  def revoke_grant(grant_id) do
    case Repo.get(Grant, grant_id) do
      nil -> {:error, :not_found}
      grant -> Repo.delete(grant)
    end
  end

  @spec revoke_all_for_bucket(integer(), user_id: integer()) :: :ok
  def revoke_all_for_bucket(bucket_id, user_id: uid) do
    Repo.delete_all(from g in Grant, where: g.bucket_id == ^bucket_id and g.user_id == ^uid)
    :ok
  end

  # ---------- Autorisierung ----------

  @doc """
  Returns :admin | :write | :read | :none for a user on a bucket.
  Admins always get :admin. The owner gets :admin.
  """
  @spec permission_for(User.t() | nil, Bucket.t()) :: :admin | :write | :read | :none
  def permission_for(%User{role: "admin"}, _bucket), do: :admin

  def permission_for(%User{id: uid} = user, %Bucket{id: bid, owner_id: owner_id}) do
    if owner_id == uid do
      :admin
    else
      group_ids = Keeplix.Accounts.user_group_ids(user)

      grants =
        Repo.all(
          from g in Grant,
            where: g.bucket_id == ^bid,
            where: g.user_id == ^uid or g.group_id in ^group_ids
        )

      level =
        Enum.reduce(grants, 0, fn g, acc ->
          max(acc, perm_level(g.permission))
        end)

      case level do
        3 -> :admin
        2 -> :write
        1 -> :read
        _ -> :none
      end
    end
  end

  def permission_for(_nil_user, _bucket), do: :none

  defp perm_level("admin"), do: 3
  defp perm_level("write"), do: 2
  defp perm_level("read"), do: 1
  defp perm_level(_), do: 0

  @spec can_read?(User.t() | nil, Bucket.t()) :: boolean()
  def can_read?(user, bucket), do: permission_for(user, bucket) in [:read, :write, :admin]
  @spec can_write?(User.t() | nil, Bucket.t()) :: boolean()
  def can_write?(user, bucket), do: permission_for(user, bucket) in [:write, :admin]
  @spec can_admin?(User.t() | nil, Bucket.t()) :: boolean()
  def can_admin?(user, bucket), do: permission_for(user, bucket) == :admin

  @spec visible_buckets(User.t()) :: [Bucket.t()]
  def visible_buckets(%User{role: "admin"}) do
    list_buckets()
  end

  def visible_buckets(%User{} = user) do
    group_ids = Keeplix.Accounts.user_group_ids(user)

    query =
      from b in Bucket,
        left_join: g in Grant,
        on: g.bucket_id == b.id,
        where: b.owner_id == ^user.id or g.user_id == ^user.id or g.group_id in ^group_ids,
        distinct: true,
        order_by: b.name

    Repo.all(query) |> Repo.preload(:owner)
  end
end
