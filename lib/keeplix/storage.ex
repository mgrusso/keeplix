defmodule Keeplix.Storage do
  @moduledoc """
  Object storage: file content on the filesystem, object metadata in the
  `objects` database table.

  Layout:
    <data_dir>/<bucket>/<key...>
    <data_dir>/multipart/<upload_id>/...

  The database row is the source of truth for listings, stats and
  content types; files are written first (atomic rename), rows second,
  so a crash can only orphan invisible files, never visible rows.
  Legacy `.keeplix-meta` sidecars are migrated by `mix keeplix.rescan_usage`.

  Kept deliberately simple (no replication in v0.1).
  See `Keeplix.Replication` for the planned push/pull sync.
  """
  import Ecto.Query

  require Logger

  alias Keeplix.Repo
  alias Keeplix.Storage.Object

  @type object_stat :: %{
          size: non_neg_integer(),
          mtime: integer(),
          etag: String.t(),
          path: String.t()
        }
  @type object_entry :: %{
          key: String.t(),
          size: non_neg_integer(),
          mtime: integer(),
          etag: String.t()
        }
  @type listing :: %{
          entries: [object_entry()],
          prefixes: [String.t()],
          truncated: boolean(),
          next_token: String.t() | nil
        }
  @type multipart_part :: %{number: integer(), size: non_neg_integer(), etag: String.t()}

  @spec data_dir() :: String.t()
  def data_dir do
    Application.get_env(:keeplix, :data_dir, Path.expand("data", File.cwd!()))
  end

  @meta_suffix ".keeplix-meta"

  # Writes `dest` atomically: content goes to a temp file in the same
  # directory first, then is renamed. Readers never see partial files and
  # concurrent writers cannot interleave; last rename wins.
  @spec atomic_write(String.t(), (String.t() -> any())) :: :ok
  defp atomic_write(dest, writer) when is_function(writer, 1) do
    tmp = dest <> ".tmp-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"

    try do
      writer.(tmp)
      File.rename!(tmp, dest)
      :ok
    rescue
      e ->
        File.rm(tmp)
        reraise e, __STACKTRACE__
    end
  end

  @spec bucket_path(String.t()) :: String.t()
  def bucket_path(bucket) when is_binary(bucket) do
    Path.join(data_dir(), sanitize_bucket!(bucket))
  end

  @doc """
  Global per-object size limit in bytes (config `:keeplix, :max_object_bytes`,
  default 5 GiB). Always enforced, independent of bucket quotas.
  """
  @spec max_object_bytes() :: pos_integer()
  def max_object_bytes do
    Application.get_env(:keeplix, :max_object_bytes, 5_368_709_312)
  end

  @doc """
  Total stored object bytes in a bucket (meta sidecars, temp files and
  folder markers excluded). Computed on demand by walking the bucket
  directory — used for repair/rescan, not on hot paths.
  """
  @spec bucket_usage(String.t()) :: non_neg_integer()
  def bucket_usage(bucket) do
    Enum.reduce(stored_files(bucket), 0, fn path, acc ->
      case File.stat(path) do
        {:ok, %{size: size}} -> acc + size
        _ -> acc
      end
    end)
  end

  @doc """
  Number of stored objects in a bucket (same exclusions as `bucket_usage/1`).
  """
  @spec bucket_object_count(String.t()) :: non_neg_integer()
  def bucket_object_count(bucket) do
    length(stored_files(bucket))
  end

  defp stored_files(bucket) do
    base = bucket_path(bucket)

    base
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&String.ends_with?(&1, @meta_suffix))
    |> Enum.reject(&Regex.match?(~r/\.tmp-[0-9a-f]{16}$/, &1))
    |> Enum.reject(&marker_file?/1)
  end

  @spec object_path(String.t(), String.t()) :: String.t()
  def object_path(bucket, key) when is_binary(bucket) and is_binary(key) do
    base = bucket_path(bucket)
    full = Path.join(base, key_to_path(key))
    # Protection against path traversal
    unless String.starts_with?(Path.expand(full), Path.expand(base)) do
      raise ArgumentError, "invalid object key"
    end

    full
  end

  defp sanitize_bucket!(bucket) do
    unless bucket =~ ~r/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/ do
      raise ArgumentError, "ungueltiger Bucket-Name: #{bucket}"
    end

    bucket
  end

  defp key_to_path(""), do: ""

  defp key_to_path(key) do
    key |> mapped_segments() |> Path.join()
  end

  defp mapped_segments(key) do
    key
    |> String.split("/", trim: false)
    |> Enum.map(fn
      "" -> ""
      "." -> "__dot__"
      ".." -> "__dotdot__"
      seg -> seg
    end)
  end

  # Folder markers must be plain (non-dot) files: Erlang's wildcard
  # never matches dotfiles, so markers would be undiscoverable. A magic
  # payload distinguishes ours from a user object that happens to share
  # the name (which is then treated as a regular object).
  @dir_marker "keeplix-dir.marker"
  @dir_marker_magic "keeplix-dir-marker-v1\n"
  @empty_etag "d41d8cd98f00b204e9800998ecf8427e"

  @spec marker_file?(String.t()) :: boolean()
  defp marker_file?(path) do
    String.ends_with?(path, "/" <> @dir_marker) and
      match?({:ok, @dir_marker_magic}, File.read(path))
  end

  @doc """
  Whether a key addresses a folder marker (`trailing slash`), which S3
  treats as a regular 0-byte object.
  """
  @spec dir_key?(String.t()) :: boolean()
  def dir_key?(key) when is_binary(key), do: String.ends_with?(key, "/")
  def dir_key?(_), do: false

  @spec ensure_data_dir!() :: :ok
  def ensure_data_dir! do
    File.mkdir_p!(data_dir())
  end

  @spec create_bucket(String.t()) :: :ok | {:error, :already_exists | File.posix()}
  def create_bucket(bucket) do
    ensure_data_dir!()

    case File.mkdir(bucket_path(bucket)) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete_bucket(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_bucket(bucket, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, true)
    path = bucket_path(bucket)

    cond do
      not File.exists?(path) ->
        :ok

      recursive ->
        File.rm_rf!(path)
        # Version contents live outside the bucket directory.
        File.rm_rf!(Path.join([data_dir(), "__versions__", sanitize_bucket!(bucket)]))
        :ok

      true ->
        case File.rmdir(path) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec bucket_exists?(String.t()) :: boolean()
  def bucket_exists?(bucket) do
    case File.stat(bucket_path(bucket)) do
      {:ok, %{type: :directory}} -> true
      _ -> false
    end
  end

  # ---------- Objects ----------

  @spec put_object(String.t(), String.t(), binary(), keyword()) ::
          {:ok, object_stat()}
          | {:error, :not_found | :object_too_large | :invalid_content_type | :key_collision}
  def put_object(bucket, key, data, opts \\ []) when is_binary(data) do
    with :ok <- check_content_type(Keyword.get(opts, :content_type)),
         :ok <- check_object_size(byte_size(data)) do
      if dir_key?(key) do
        write_dir_marker(bucket, key)
      else
        with :ok <- check_no_collision(bucket, key),
             record when not is_nil(record) <- bucket_record(bucket) do
          content_type = Keyword.get(opts, :content_type)

          if record.versioning == "enabled" do
            store_versioned(bucket, record, key, content_type, &File.write!(&1, data))
          else
            path = object_path(bucket, key)
            File.mkdir_p!(Path.dirname(path))
            atomic_write(path, &File.write!(&1, data))
            etag = etag_for_binary(data)

            case upsert_row_for(bucket, key, %{etag: etag, content_type: content_type}) do
              :ok -> stat_object(bucket, key)
              {:error, _} = err -> err
            end
          end
        else
          {:error, :key_collision} = err -> err
          _ -> {:error, :not_found}
        end
      end
    end
  end

  @spec put_object_from_file(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, object_stat()}
          | {:error, :not_found | :object_too_large | :invalid_content_type | :key_collision}
  def put_object_from_file(bucket, key, tmp_path, opts \\ []) do
    with :ok <- check_content_type(Keyword.get(opts, :content_type)),
         {:ok, %{size: size}} <- File.stat(tmp_path),
         :ok <- check_object_size(size) do
      if dir_key?(key) do
        write_dir_marker(bucket, key)
      else
        with :ok <- check_no_collision(bucket, key),
             record when not is_nil(record) <- bucket_record(bucket) do
          content_type = Keyword.get(opts, :content_type)

          if record.versioning == "enabled" do
            store_versioned(bucket, record, key, content_type, &File.cp!(tmp_path, &1))
          else
            path = object_path(bucket, key)
            File.mkdir_p!(Path.dirname(path))
            atomic_write(path, &File.cp!(tmp_path, &1))
            etag = etag_for_file(path)

            case upsert_row_for(bucket, key, %{
                   etag: etag,
                   content_type: content_type
                 }) do
              :ok -> stat_object(bucket, key)
              {:error, _} = err -> err
            end
          end
        else
          {:error, :key_collision} = err -> err
          _ -> {:error, :not_found}
        end
      end
    else
      {:error, :object_too_large} = err -> err
      {:error, :invalid_content_type} = err -> err
      {:error, :key_collision} = err -> err
      {:error, _} -> {:error, :not_found}
    end
  end

  # Stores the row for a just-written file (size read back from disk).
  # On row failure the file is removed again, so rows never dangle.
  defp upsert_row_for(bucket, key, attrs) do
    path = object_path(bucket, key)

    with {:ok, %{size: size}} <- File.stat(path),
         id when not is_nil(id) <- bucket_id(bucket),
         # A fresh PUT revives a trashed row in place.
         {:ok, _} <-
           upsert_row(id, key, Map.merge(attrs, %{size: size, trashed: false, trashed_at: nil})) do
      :ok
    else
      _ ->
        File.rm(path)
        {:error, :not_found}
    end
  end

  # Folder markers ("data/") are real 0-byte objects backed by a directory
  # plus a marker file.
  @spec write_dir_marker(String.t(), String.t()) ::
          {:ok, object_stat()} | {:error, :key_collision}
  defp write_dir_marker(bucket, key) do
    case String.trim_trailing(key, "/") do
      "" ->
        {:error, :key_collision}

      trimmed ->
        dir = object_path(bucket, trimmed)

        with {:ok, %{type: :directory}} <- ensure_marker_dir(dir),
             record when not is_nil(record) <- bucket_record(bucket) do
          marker = Path.join(dir, @dir_marker)
          File.write!(marker, @dir_marker_magic)
          {:ok, %{mtime: mtime}} = File.stat(marker, time: :posix)

          if record.versioning == "enabled" do
            case insert_new_version(record.id, key, gen_version_id(), %{
                   size: 0,
                   etag: @empty_etag,
                   content_type: nil
                 }) do
              {:ok, row} ->
                {:ok,
                 %{
                   size: 0,
                   mtime: mtime,
                   etag: @empty_etag,
                   path: marker,
                   version_id: row.version_id
                 }}

              {:error, _} ->
                {:error, :not_found}
            end
          else
            case upsert_row(record.id, key, %{size: 0, etag: @empty_etag, content_type: nil}) do
              {:ok, row} ->
                {:ok,
                 %{
                   size: 0,
                   mtime: mtime,
                   etag: @empty_etag,
                   path: marker,
                   version_id: row.version_id
                 }}

              {:error, _} ->
                {:error, :not_found}
            end
          end
        else
          _ -> {:error, :key_collision}
        end
    end
  end

  defp ensure_marker_dir(dir) do
    case File.stat(dir) do
      {:ok, %{type: :directory}} ->
        {:ok, %{type: :directory}}

      {:error, _} ->
        case File.mkdir_p(dir) do
          :ok -> {:ok, %{type: :directory}}
          {:error, _} -> {:error, :key_collision}
        end

      {:ok, _} ->
        {:error, :key_collision}
    end
  end

  # A key collides when an ancestor path component is a regular file, or
  # when the destination itself is a directory. Either case used to crash
  # with a 500 (File.Error / :eisdir); now it is a clean 400.
  @spec check_no_collision(String.t(), String.t()) :: :ok | {:error, :key_collision}
  defp check_no_collision(bucket, key) do
    base = bucket_path(bucket)
    segments = mapped_segments(key)
    ancestors = for i <- 0..(length(segments) - 1), do: Enum.take(segments, i)

    ancestors_ok? =
      Enum.all?(ancestors, fn segs ->
        full = if segs == [], do: base, else: Path.join([base | segs])

        case File.stat(full) do
          {:ok, %{type: :regular}} -> false
          _ -> true
        end
      end)

    dest_ok? =
      case File.stat(object_path(bucket, key)) do
        {:ok, %{type: :directory}} -> false
        _ -> true
      end

    if ancestors_ok? and dest_ok?, do: :ok, else: {:error, :key_collision}
  end

  @spec check_object_size(non_neg_integer()) :: :ok | {:error, :object_too_large}
  defp check_object_size(size) do
    if size <= max_object_bytes(), do: :ok, else: {:error, :object_too_large}
  end

  # Content types are stored and later reflected into response headers;
  # only accept well-formed `type/subtype` values ( printable ASCII,
  # no control characters that could smuggle headers).
  @spec check_content_type(String.t() | nil) :: :ok | {:error, :invalid_content_type}
  defp check_content_type(nil), do: :ok

  defp check_content_type(ct) when is_binary(ct) do
    if byte_size(ct) in 1..255 and Regex.match?(~r"\A[!-~]+/[!-~]+(\s*;\s*[!-~ ]+)?\z", ct) do
      :ok
    else
      {:error, :invalid_content_type}
    end
  end

  defp check_content_type(_), do: {:error, :invalid_content_type}

  @spec check_parts_size([String.t()]) :: :ok | {:error, :object_too_large}
  defp check_parts_size(part_paths) do
    total =
      Enum.reduce(part_paths, 0, fn path, acc ->
        case File.stat(path) do
          {:ok, %{size: size}} -> acc + size
          _ -> acc
        end
      end)

    check_object_size(total)
  end

  @spec bucket_id(String.t()) :: integer() | nil
  defp bucket_id(name) when is_binary(name) do
    case Repo.get_by(Keeplix.Buckets.Bucket, name: name) do
      nil -> nil
      bucket -> bucket.id
    end
  end

  @spec bucket_record(String.t()) :: Keeplix.Buckets.Bucket.t() | nil
  defp bucket_record(name) when is_binary(name) do
    Repo.get_by(Keeplix.Buckets.Bucket, name: name)
  end

  @spec gen_version_id() :: String.t()
  defp gen_version_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  @doc """
  Content file for a non-null version. Null versions live at the plain
  key path (backward compatible); markers share one file per directory.
  """
  @spec version_file(String.t(), String.t()) :: String.t()
  def version_file(bucket, version_id) do
    Path.join([data_dir(), "__versions__", sanitize_bucket!(bucket), version_id])
  end

  defp demote_latest(bucket_id, key) do
    Repo.update_all(
      from(o in Object,
        where: o.bucket_id == ^bucket_id and o.key == ^key and o.is_latest == true
      ),
      set: [is_latest: false]
    )

    :ok
  end

  defp insert_new_version(bucket_id, key, version_id, attrs) do
    Repo.transaction(fn ->
      demote_latest(bucket_id, key)

      %Object{bucket_id: bucket_id}
      |> Object.changeset(
        Map.merge(attrs, %{key: key, version_id: version_id, is_latest: true, deleted: false})
      )
      |> Repo.insert!()
    end)
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, _} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  # Stores content as a fresh version (enabled buckets). `writer` receives
  # a temp path inside the version file's directory.
  defp store_versioned(bucket, record, key, content_type, writer) do
    version_id = gen_version_id()
    dest = version_file(bucket, version_id)
    File.mkdir_p!(Path.dirname(dest))
    atomic_write(dest, writer)
    etag = etag_for_file(dest)
    {:ok, %{size: size}} = File.stat(dest)

    case insert_new_version(record.id, key, version_id, %{
           size: size,
           etag: etag,
           content_type: content_type
         }) do
      {:ok, _} ->
        stat_object(bucket, key)

      {:error, _} ->
        File.rm(dest)
        {:error, :not_found}
    end
  end

  @spec upsert_row(integer(), String.t(), map()) :: {:ok, Object.t()} | {:error, term()}
  defp upsert_row(bucket_id, key, attrs) do
    # The null row is unique per key, but other versions may be latest
    # (e.g. suspended buckets) — demote everything first so exactly one
    # latest row remains.
    Repo.transaction(fn ->
      demote_latest(bucket_id, key)

      %Object{bucket_id: bucket_id}
      |> Object.changeset(Map.put(attrs, :key, key))
      |> Repo.insert!(
        on_conflict: {:replace_all_except, [:id, :bucket_id, :key, :inserted_at]},
        conflict_target: [:bucket_id, :key, :version_id]
      )
    end)
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, _} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @spec get_content_type(String.t(), String.t(), String.t()) :: String.t()
  def get_content_type(bucket, key, default \\ "application/octet-stream") do
    with id when not is_nil(id) <- bucket_id(bucket),
         %Object{content_type: ct} when is_binary(ct) <- latest_live_row(id, key) do
      ct
    else
      _ -> default
    end
  end

  @spec stat_object(String.t(), String.t()) :: {:ok, object_stat()} | {:error, :not_found}
  def stat_object(bucket, key) do
    with id when not is_nil(id) <- bucket_id(bucket),
         %Object{} = row <- latest_live_row(id, key) do
      row_stat(bucket, row)
    else
      _ -> {:error, :not_found}
    end
  end

  @spec stat_version(String.t(), String.t(), String.t()) ::
          {:ok, object_stat()} | {:marker, Object.t()} | {:error, :not_found}
  def stat_version(bucket, key, version_id) when is_binary(version_id) do
    case get_version(bucket, key, version_id) do
      {:ok, row} -> row_stat(bucket, row)
      {:marker, _} = marker -> marker
      {:error, _} -> {:error, :not_found}
    end
  end

  @spec row_stat(String.t(), Object.t()) :: {:ok, object_stat()} | {:error, :not_found}
  def row_stat(bucket, %Object{} = row) do
    case row_file(bucket, row) do
      {:ok, path} ->
        {:ok,
         %{
           size: row.size,
           mtime: to_unix(row.updated_at),
           etag: row.etag,
           path: path,
           version_id: row.version_id,
           content_type: row.content_type,
           tags: decode_tags(row.tags)
         }}

      :error ->
        Logger.warning("object row without file", bucket: bucket, key: row.key)
        {:error, :not_found}
    end
  end

  defp latest_live_row(bucket_id, key) do
    Repo.one(
      from o in Object,
        where:
          o.bucket_id == ^bucket_id and o.key == ^key and o.is_latest == true and
            o.deleted == false and o.trashed == false
    )
  end

  # Resolves the servable filesystem path, verifying presence. A row whose
  # file vanished reads as missing (the rescan task reconciles).
  defp row_file(bucket, %Object{key: key, version_id: version}) do
    cond do
      dir_key?(key) ->
        case String.trim_trailing(key, "/") do
          "" ->
            :error

          trimmed ->
            marker = Path.join(object_path(bucket, trimmed), @dir_marker)
            if marker_file?(marker), do: {:ok, marker}, else: :error
        end

      version in [nil, "null"] ->
        path = object_path(bucket, key)
        if File.regular?(path), do: {:ok, path}, else: :error

      true ->
        path = version_file(bucket, version)
        if File.regular?(path), do: {:ok, path}, else: :error
    end
  end

  defp to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp to_unix(_), do: 0

  @spec object_exists?(String.t(), String.t()) :: boolean()
  def object_exists?(bucket, key) do
    match?({:ok, _}, stat_object(bucket, key))
  end

  @spec delete_object(String.t(), String.t()) :: :ok
  def delete_object(bucket, key) do
    if dir_key?(key) do
      delete_marker_object(bucket, key)
    else
      case bucket_record(bucket) do
        %{versioning: "enabled"} ->
          delete_marker_version(bucket, key)

        %{versioning: "suspended"} ->
          delete_null_object(bucket, key)
          delete_marker_version(bucket, key)

        _ ->
          delete_null_object(bucket, key)
      end
    end

    :ok
  end

  # Unversioned (or suspended) delete: the null row moves to trash, its
  # file stays until purged. Restorable via restore_object/2.
  defp delete_null_object(bucket, key) do
    with id when not is_nil(id) <- bucket_id(bucket),
         %Object{} = row <-
           Repo.get_by(Object, bucket_id: id, key: key, version_id: "null") do
      trash_row(row)

      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # ---------- Trash ----------

  @doc """
  Lists trashed objects of a bucket (newest first).
  """
  @spec list_trash(String.t()) :: {:ok, [map()]} | {:error, :no_such_bucket}
  def list_trash(bucket) do
    with id when not is_nil(id) <- bucket_id(bucket) do
      rows =
        Repo.all(
          from o in Object,
            where: o.bucket_id == ^id and o.trashed == true,
            order_by: [desc: o.trashed_at, desc: o.id]
        )

      {:ok, Enum.map(rows, &%{key: &1.key, size: &1.size, trashed_at: &1.trashed_at})}
    else
      _ -> {:error, :no_such_bucket}
    end
  end

  @doc """
  Restores a trashed object. Fails with `:key_exists` when a live object
  reclaimed the key in the meantime (delete it or rename first).
  """
  @spec restore_object(String.t(), String.t()) :: :ok | {:error, :not_found | :key_exists}
  def restore_object(bucket, key) do
    with id when not is_nil(id) <- bucket_id(bucket),
         %Object{id: row_id} <- Repo.get_by(Object, bucket_id: id, key: key, trashed: true),
         nil <- latest_live_row(id, key) do
      # update_all (not a changeset on a stale struct): demote touched
      # is_latest after the struct was read.
      Repo.update_all(
        from(o in Object, where: o.bucket_id == ^id and o.key == ^key and o.id != ^row_id),
        set: [is_latest: false]
      )

      case Repo.update_all(from(o in Object, where: o.id == ^row_id),
             set: [trashed: false, trashed_at: nil, is_latest: true]
           ) do
        {1, _} ->
          if dir_key?(key), do: sync_marker_file(bucket, key)
          :ok

        _ ->
          {:error, :not_found}
      end
    else
      nil -> {:error, :not_found}
      %Object{} -> {:error, :key_exists}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Permanently deletes a trashed object (row + file).
  """
  @spec purge_object(String.t(), String.t()) :: :ok
  def purge_object(bucket, key) do
    with id when not is_nil(id) <- bucket_id(bucket),
         %Object{} = row <- Repo.get_by(Object, bucket_id: id, key: key, trashed: true) do
      Repo.delete(row)

      if dir_key?(key) do
        sync_marker_file(bucket, key)
      else
        File.rm(object_path(bucket, key))
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Permanently deletes all trashed objects of a bucket.
  """
  @spec empty_trash(String.t()) :: {:ok, non_neg_integer()} | {:error, :no_such_bucket}
  def empty_trash(bucket) do
    with {:ok, rows} <- list_trash(bucket) do
      Enum.each(rows, &purge_object(bucket, &1.key))
      {:ok, length(rows)}
    end
  end

  @doc """
  Purges trashed objects older than `days`. Returns `{:ok, count}`.
  """
  @spec purge_trashed_older_than(String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :no_such_bucket}
  def purge_trashed_older_than(bucket, days) do
    with {:ok, rows} <- list_trash(bucket) do
      cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

      count =
        Enum.count(rows, fn %{key: key, trashed_at: trashed_at} ->
          if trashed_at != nil and DateTime.compare(trashed_at, cutoff) == :lt do
            purge_object(bucket, key)
            true
          else
            false
          end
        end)

      {:ok, count}
    end
  end

  defp trash_row(%Object{} = row) do
    row
    |> Object.changeset(%{
      trashed: true,
      trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  defp delete_marker_object(bucket, key) do
    case bucket_record(bucket) do
      %{versioning: versioning} when versioning in ["enabled", "suspended"] ->
        if versioning == "suspended", do: delete_null_object(bucket, key)
        delete_marker_version(bucket, key)

      _ ->
        delete_marker_row(bucket, key)
    end
  end

  defp delete_marker_row(bucket, key) do
    with id when not is_nil(id) <- bucket_id(bucket),
         %Object{} = row <-
           Repo.get_by(Object, bucket_id: id, key: key, version_id: "null") do
      trash_row(row)
    else
      _ -> :ok
    end

    sync_marker_file(bucket, key)
  end

  # Versioned delete: a fresh delete marker becomes latest (S3 semantics,
  # also for suspended buckets).
  defp delete_marker_version(bucket, key) do
    with id when not is_nil(id) <- bucket_id(bucket),
         :ok <- ensure_marker_backing(bucket, key),
         version_id = gen_version_id(),
         {:ok, _} <-
           Repo.transaction(fn ->
             demote_latest(id, key)

             %Object{bucket_id: id}
             |> Object.changeset(%{
               key: key,
               version_id: version_id,
               size: 0,
               etag: @empty_etag,
               is_latest: true,
               deleted: true
             })
             |> Repo.insert!()
           end) do
      sync_marker_file(bucket, key)
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # Shared marker file backing for versioned marker operations; file
  # keys need no directory setup.
  defp ensure_marker_backing(bucket, key) do
    if dir_key?(key) do
      ensure_marker_dir_for(bucket, key)
    else
      :ok
    end
  end

  defp ensure_marker_dir_for(bucket, key) do
    case String.trim_trailing(key, "/") do
      "" ->
        {:error, :invalid_key}

      trimmed ->
        case ensure_marker_dir(object_path(bucket, trimmed)) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :key_collision}
        end
    end
  end

  @doc """
  Deletes one explicit version. The newest remaining version becomes
  latest again. Unknown versions read as `:no_such_version`.
  """
  @spec delete_version(String.t(), String.t(), String.t()) :: :ok | {:error, :no_such_version}
  def delete_version(bucket, key, version_id) when is_binary(version_id) do
    with id when not is_nil(id) <- bucket_id(bucket),
         %Object{} = row <-
           Repo.get_by(Object, bucket_id: id, key: key, version_id: version_id) do
      Repo.delete(row)
      remove_version_file(bucket, row)
      promote_newest(id, key)
      sync_marker_file(bucket, key)
      :ok
    else
      _ -> {:error, :no_such_version}
    end
  end

  def delete_version(_, _, _), do: {:error, :no_such_version}

  defp remove_version_file(bucket, %Object{version_id: v}) when v not in [nil, "null"] do
    File.rm(version_file(bucket, v))
    :ok
  end

  defp remove_version_file(bucket, %Object{key: key, version_id: v}) when v in [nil, "null"] do
    # Null versions live at the key path (or the shared marker file,
    # which stays while other marker versions reference the directory).
    unless dir_key?(key) do
      File.rm(object_path(bucket, key))
    end

    :ok
  end

  defp promote_newest(bucket_id, key) do
    case Repo.one(
           from o in Object,
             where: o.bucket_id == ^bucket_id and o.key == ^key,
             order_by: [desc: o.inserted_at, desc: o.id],
             limit: 1
         ) do
      nil ->
        :ok

      %Object{id: id} ->
        Repo.update_all(from(o in Object, where: o.id == ^id), set: [is_latest: true])
        :ok
    end
  end

  # Marker file lifecycle: the shared file exists iff at least one
  # marker row references the directory.
  defp sync_marker_file(bucket, key) do
    if dir_key?(key) do
      case String.trim_trailing(key, "/") do
        "" ->
          :ok

        trimmed ->
          with id when not is_nil(id) <- bucket_id(bucket),
               dir = object_path(bucket, trimmed),
               marker = Path.join(dir, @dir_marker),
               remaining <-
                 Repo.aggregate(
                   from(o in Object, where: o.bucket_id == ^id and o.key == ^key),
                   :count
                 ) do
            if remaining > 0 do
              unless marker_file?(marker), do: File.write!(marker, @dir_marker_magic)
            else
              File.rm(marker)
              File.rmdir(dir)
            end

            :ok
          else
            _ -> :ok
          end
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Server-side copy of an object (same or cross bucket). Content type is
  carried over unless replaced; the ETag is recomputed for the destination.
  Options: `:source_version_id`, `:content_type` (S3 CopyObject).
  """
  @spec copy_object(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, object_stat()} | {:error, :not_found | :object_too_large | :key_collision}
  def copy_object(dest_bucket, dest_key, src_bucket, src_key, opts \\ []) do
    cond do
      dir_key?(src_key) and dir_key?(dest_key) ->
        copy_dir_marker(dest_bucket, dest_key, src_bucket, src_key)

      dir_key?(src_key) or dir_key?(dest_key) ->
        {:error, :key_collision}

      true ->
        copy_file_object(dest_bucket, dest_key, src_bucket, src_key, opts)
    end
  end

  defp copy_dir_marker(dest_bucket, dest_key, src_bucket, src_key) do
    # write_dir_marker rejects a regular file blocking the destination.
    with {:ok, _} <- stat_object(src_bucket, src_key) do
      write_dir_marker(dest_bucket, dest_key)
    end
  end

  defp copy_file_object(dest_bucket, dest_key, src_bucket, src_key, opts) do
    with {:ok, src_stat} <-
           copy_source_stat(src_bucket, src_key, Keyword.get(opts, :source_version_id)),
         %{size: size, path: src_path} <- src_stat,
         :ok <- check_object_size(size),
         :ok <- check_no_collision(dest_bucket, dest_key),
         dest_record when not is_nil(dest_record) <- bucket_record(dest_bucket) do
      content_type =
        Keyword.get(opts, :content_type) || src_stat[:content_type] ||
          get_content_type(src_bucket, src_key)

      if dest_record.versioning == "enabled" do
        store_versioned(dest_bucket, dest_record, dest_key, content_type, &File.cp!(src_path, &1))
      else
        dest = object_path(dest_bucket, dest_key)
        File.mkdir_p!(Path.dirname(dest))
        atomic_write(dest, &File.cp!(src_path, &1))
        etag = etag_for_file(dest)

        case upsert_row(dest_record.id, dest_key, %{
               size: byte_size_of(dest),
               etag: etag,
               content_type: content_type
             }) do
          {:ok, _} -> stat_object(dest_bucket, dest_key)
          {:error, _} -> {:error, :not_found}
        end
      end
    end
  end

  defp copy_source_stat(bucket, key, nil), do: stat_object(bucket, key)

  defp copy_source_stat(bucket, key, version_id) do
    case stat_version(bucket, key, version_id) do
      {:ok, stat} -> {:ok, stat}
      {:marker, _} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp byte_size_of(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  @doc """
  Rename within a bucket (copy + delete).
  """
  @spec rename_object(String.t(), String.t(), String.t()) ::
          {:ok, object_stat()} | {:error, :not_found | :object_too_large}
  def rename_object(bucket, src_key, dest_key) do
    with {:ok, stat} <- copy_object(bucket, dest_key, bucket, src_key) do
      delete_object(bucket, src_key)
      {:ok, stat}
    end
  end

  @spec etag_for_file(String.t()) :: String.t()
  def etag_for_file(path) do
    path
    |> File.stream!(64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:md5), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @spec etag_for_binary(binary()) :: String.t()
  def etag_for_binary(data), do: :crypto.hash(:md5, data) |> Base.encode16(case: :lower)

  @doc """
  Lists objects in S3 ListV2 style.
  Keys come from the `objects` table (ordered, prefix-filtered in SQL);
  delimiter grouping and paging stay in Elixir.
  """
  @spec list_objects(String.t(), keyword()) :: {:ok, listing()} | {:error, :no_such_bucket}
  def list_objects(bucket, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")
    delimiter = Keyword.get(opts, :delimiter, nil)
    max_keys = opts |> Keyword.get(:max_keys, 1000) |> max(0) |> min(1000)
    continuation = Keyword.get(opts, :continuation_token, nil)
    start_after = Keyword.get(opts, :start_after, nil)

    with id when not is_nil(id) <- bucket_id(bucket),
         true <- File.dir?(bucket_path(bucket)) do
      {keys, prefixes, is_truncated, next_token, by_key} =
        page_keys(id, prefix, delimiter, start_after || continuation, max_keys)

      entries =
        Enum.map(keys, fn key ->
          row = Map.fetch!(by_key, key)
          %{key: key, size: row.size, mtime: to_unix(row.updated_at), etag: row.etag}
        end)

      {:ok,
       %{entries: entries, prefixes: prefixes, truncated: is_truncated, next_token: next_token}}
    else
      _ -> {:error, :no_such_bucket}
    end
  end

  # Plain (delimiter-less) listing: rows map 1:1 to contents.
  defp page_keys(id, prefix, nil, start, max_keys) do
    rows = list_rows(id, prefix, start, max_keys + 1)
    keys = Enum.map(rows, & &1.key)
    {page, is_truncated, next_token} = paginate(keys, max_keys)
    {page, [], is_truncated, next_token, Map.new(rows, &{&1.key, &1})}
  end

  # Degenerate page: probe whether anything exists at all.
  defp page_keys(id, prefix, _delimiter, start, 0) do
    rows = list_rows(id, prefix, start, 1)
    {[], [], rows != [], nil, %{}}
  end

  # Delimited listing: contents and prefixes share the max_keys budget.
  # Rows collapse (many rows -> one prefix), so pages are assembled by
  # scanning until the budget is full or the keyspace is exhausted.
  defp page_keys(id, prefix, delimiter, start, max_keys) do
    {contents, prefixes, is_truncated, next_token, by_key} =
      collect_delimited(id, prefix, delimiter, start, max_keys, [], MapSet.new(), 0, %{})

    {contents, prefixes |> MapSet.to_list() |> Enum.sort(), is_truncated, next_token, by_key}
  end

  defp collect_delimited(
         id,
         prefix,
         delimiter,
         token,
         max_keys,
         contents_rev,
         prefixes,
         count,
         by_key
       ) do
    # Over-fetch: duplicate-prefix rows collapse without filling the page.
    rows = list_rows(id, prefix, token, max(max_keys + 1, 250))
    by_key = Map.merge(by_key, Map.new(rows, &{&1.key, &1}))

    {contents_rev, prefixes, count, consumed, status} =
      fold_rows(rows, prefix, delimiter, max_keys, contents_rev, prefixes, count, [])

    last_key = List.first(consumed)

    cond do
      status == :full ->
        finish_delimited(
          id,
          prefix,
          delimiter,
          rows,
          consumed,
          contents_rev,
          prefixes,
          last_key,
          by_key
        )

      length(rows) < max(max_keys + 1, 250) ->
        {Enum.reverse(contents_rev), prefixes, false, nil, by_key}

      true ->
        collect_delimited(
          id,
          prefix,
          delimiter,
          last_key,
          max_keys,
          contents_rev,
          prefixes,
          count,
          by_key
        )
    end
  end

  # Folds one batch, stopping early once the page budget is full.
  # consumed is a reverse list of consumed row keys (most recent first).
  defp fold_rows([], _prefix, _delimiter, _max, contents, prefixes, count, consumed),
    do: {contents, prefixes, count, consumed, :batch_done}

  defp fold_rows(_rows, _prefix, _delimiter, max, contents, prefixes, count, consumed)
       when count >= max,
       do: {contents, prefixes, count, consumed, :full}

  defp fold_rows([row | rest], prefix, delimiter, max, contents, prefixes, count, consumed) do
    {contents, prefixes, count} =
      case classify_key(row.key, prefix, delimiter) do
        {:content, key} ->
          {[key | contents], prefixes, count + 1}

        {:prefix, p} ->
          if MapSet.member?(prefixes, p),
            do: {contents, prefixes, count},
            else: {contents, MapSet.put(prefixes, p), count + 1}
      end

    fold_rows(rest, prefix, delimiter, max, contents, prefixes, count, [row.key | consumed])
  end

  defp classify_key(key, prefix, delimiter) do
    rest = String.replace_prefix(key, prefix, "")

    case String.split(rest, delimiter, parts: 2) do
      [_single] -> {:content, key}
      [first, _] -> {:prefix, prefix <> first <> delimiter}
    end
  end

  # The page budget is full. A trailing content ends the page cleanly;
  # a trailing prefix must be drained (same-prefix rows are consumed
  # without counting) so the next page never repeats it.
  defp finish_delimited(
         id,
         prefix,
         delimiter,
         fetched,
         consumed,
         contents_rev,
         prefixes,
         last_key,
         by_key
       ) do
    contents = Enum.reverse(contents_rev)
    leftover = Enum.drop(fetched, length(consumed)) |> Enum.map(& &1.key)

    case classify_key(last_key, prefix, delimiter) do
      {:content, _} ->
        {contents, prefixes, true, last_key, by_key}

      {:prefix, p} ->
        {drain_last, more?} = drain_prefix(id, prefix, leftover, p, last_key)

        if more? do
          {contents, prefixes, true, drain_last, by_key}
        else
          {contents, prefixes, false, nil, by_key}
        end
    end
  end

  # Consumes in-hand rows belonging to the trailing prefix, then probes
  # the database while the prefix continues. Returns the last drained
  # key and whether rows remain beyond the prefix.
  defp drain_prefix(id, prefix, leftover, drain_p, last_key) do
    {last_key, rest} = consume_while_prefix(leftover, drain_p, last_key)

    case rest do
      [_ | _] ->
        {last_key, true}

      [] ->
        case list_rows(id, prefix, last_key, 1) do
          [] ->
            {last_key, false}

          [%{key: key}] ->
            if String.starts_with?(key, drain_p),
              do: drain_db_prefix(id, prefix, drain_p, key),
              else: {last_key, true}
        end
    end
  end

  defp consume_while_prefix([], _drain_p, last_key), do: {last_key, []}

  defp consume_while_prefix([key | rest], drain_p, last_key) do
    if String.starts_with?(key, drain_p),
      do: consume_while_prefix(rest, drain_p, key),
      else: {last_key, [key | rest]}
  end

  defp drain_db_prefix(id, prefix, drain_p, token) do
    rows = list_rows(id, prefix, token, 101)
    in_prefix = Enum.take_while(rows, &String.starts_with?(&1.key, drain_p))
    last = in_prefix |> List.last() |> then(fn row -> row && row.key end)

    cond do
      last == nil ->
        {token, true}

      length(in_prefix) < length(rows) ->
        {last, true}

      length(rows) < 101 ->
        {last, false}

      true ->
        drain_db_prefix(id, prefix, drain_p, last)
    end
  end

  # Ordered key lookup with an anchored GLOB (case-sensitive, unlike LIKE).
  # Only current live versions surface in standard listings; history and
  # delete markers stay addressable via version ids. The continuation
  # token becomes a lower bound, so deep S3 pagination stays correct
  # without loading the whole keyspace.
  defp list_rows(bucket_id, prefix, start_token, limit) do
    query =
      from o in Object,
        where: o.bucket_id == ^bucket_id,
        where: o.is_latest == true and o.deleted == false and o.trashed == false,
        where: fragment("? GLOB ?", o.key, ^(escape_glob(prefix) <> "*")),
        order_by: o.key,
        limit: ^limit

    query =
      if start_token not in [nil, ""] do
        where(query, [o], o.key > ^start_token)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Fetches one explicit version (nil for the current one). Delete markers
  come back as `{:marker, row}` so callers can answer 404 + header.
  """
  @spec get_version(String.t(), String.t(), String.t() | nil) ::
          {:ok, Object.t()} | {:marker, Object.t()} | {:error, :not_found}
  def get_version(bucket, key, nil) do
    with id when not is_nil(id) <- bucket_id(bucket),
         %Object{} = row <-
           Repo.one(
             from o in Object,
               where:
                 o.bucket_id == ^id and o.key == ^key and o.is_latest == true and
                   o.trashed == false
           ) do
      if row.deleted, do: {:marker, row}, else: {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_version(bucket, key, version_id) when is_binary(version_id) do
    with id when not is_nil(id) <- bucket_id(bucket),
         %Object{} = row <-
           Repo.one(
             from o in Object,
               where:
                 o.bucket_id == ^id and o.key == ^key and o.version_id == ^version_id and
                   o.trashed == false
           ) do
      if row.deleted, do: {:marker, row}, else: {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  @canned_acls ~w(private public-read public-read-write authenticated-read
    bucket-owner-read bucket-owner-full-control log-delivery-write)

  @doc """
  Canned ACLs accepted by keeplix. Stored and reported for SDK
  compatibility; effective access stays grant-based (deny by default —
  keeplix offers no anonymous access).
  """
  @spec canned_acls() :: [String.t()]
  def canned_acls, do: @canned_acls

  @spec valid_acl?(term()) :: boolean()
  def valid_acl?(acl) when is_binary(acl), do: acl in @canned_acls
  def valid_acl?(_), do: false

  @doc """
  Reads the canned ACL of an object version (latest when nil).
  """
  @spec get_object_acl(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :not_found}
  def get_object_acl(bucket, key, version_id \\ nil) do
    case get_version(bucket, key, version_id) do
      {:ok, row} -> {:ok, row.acl || "private"}
      _ -> {:error, :not_found}
    end
  end

  @spec put_object_acl(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, :not_found | :invalid_acl}
  def put_object_acl(bucket, key, acl, version_id \\ nil) do
    with true <- valid_acl?(acl),
         {:ok, row} <- get_version(bucket, key, version_id),
         {:ok, _} <- row |> Object.changeset(%{acl: acl}) |> Repo.update() do
      :ok
    else
      false -> {:error, :invalid_acl}
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :invalid_acl}
    end
  end

  @doc """
  Object tags (S3 Tagging, per version row). Returns the tag map.
  """
  @spec get_object_tags(String.t(), String.t(), String.t() | nil) ::
          {:ok, %{String.t() => String.t()}} | {:error, :not_found}
  def get_object_tags(bucket, key, version_id \\ nil) do
    case get_version(bucket, key, version_id) do
      {:ok, row} -> {:ok, decode_tags(row.tags)}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Replaces the tag set of an object version (latest when `version_id`
  is nil). Validates S3 tag limits.
  """
  @spec put_object_tags(String.t(), String.t(), map(), String.t() | nil) ::
          :ok | {:error, :not_found | :invalid_tags}
  def put_object_tags(bucket, key, tags, version_id \\ nil) do
    with :ok <- validate_tags(tags),
         {:ok, row} <- get_version(bucket, key, version_id),
         {:ok, _} <-
           row |> Object.changeset(%{tags: encode_tags(tags)}) |> Repo.update() do
      :ok
    else
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :invalid_tags}
    end
  end

  @spec delete_object_tags(String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, :not_found | :invalid_tags}
  def delete_object_tags(bucket, key, version_id \\ nil),
    do: put_object_tags(bucket, key, %{}, version_id)

  @doc """
  Copies the tag set from a source version to the latest row of the
  destination key (S3 CopyObject with tagging-directive COPY).
  """
  @spec copy_object_tags(String.t(), String.t(), String.t() | nil, String.t(), String.t()) ::
          :ok | {:error, :not_found | :invalid_tags}
  def copy_object_tags(src_bucket, src_key, version_id, dest_bucket, dest_key) do
    with {:ok, tags} <- get_object_tags(src_bucket, src_key, version_id) do
      put_object_tags(dest_bucket, dest_key, tags)
    end
  end

  @tag_key_re ~r/^[a-zA-Z0-9 +\-.=_:\/@]+$/

  @doc """
  S3 tag limits: max 10 tags, key 1-128 chars (no `aws:` prefix),
  value max 256 chars.
  """
  @spec validate_tags(term()) :: :ok | {:error, :invalid_tags}
  def validate_tags(tags) when is_map(tags) and map_size(tags) <= 10 do
    if Enum.all?(tags, fn {k, v} ->
         is_binary(k) and is_binary(v) and k != "" and byte_size(k) <= 128 and
           byte_size(v) <= 256 and k =~ @tag_key_re and not String.starts_with?(k, "aws:")
       end) do
      :ok
    else
      {:error, :invalid_tags}
    end
  end

  def validate_tags(_), do: {:error, :invalid_tags}

  defp encode_tags(tags), do: Jason.encode!(tags)

  defp decode_tags(nil), do: %{}
  defp decode_tags(""), do: %{}

  defp decode_tags(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
      _ -> %{}
    end
  end

  @doc """
  Applies enabled lifecycle expiration rules: objects older than `days`
  under the rule prefix are deleted (versioned buckets get a delete
  marker, like S3). Returns `{:ok, %{expired: n}}`.
  """
  @spec apply_lifecycle(String.t(), DateTime.t()) ::
          {:ok, %{expired: non_neg_integer()}} | {:error, :no_such_bucket}
  def apply_lifecycle(bucket, now \\ DateTime.utc_now()) do
    with id when not is_nil(id) <- bucket_id(bucket) do
      now_unix = DateTime.to_unix(now)
      rules = Keeplix.Buckets.get_lifecycle_config(bucket)

      expired =
        rules
        |> Enum.filter(&(&1["status"] == "Enabled"))
        |> Enum.reduce(0, fn rule, acc -> acc + expire_rule(bucket, rule, now_unix) end)

      {:ok, %{expired: expired}}
    else
      _ -> {:error, :no_such_bucket}
    end
  end

  defp expire_rule(bucket, %{"prefix" => prefix, "days" => days}, now_unix) do
    bucket
    |> all_keys(prefix || "")
    |> Enum.count(fn key ->
      case stat_object(bucket, key) do
        {:ok, %{mtime: mtime}} when now_unix - mtime >= days * 86_400 ->
          delete_object(bucket, key) == :ok

        _ ->
          false
      end
    end)
  end

  defp all_keys(bucket, prefix, token \\ nil, acc \\ []) do
    case list_objects(bucket, prefix: prefix, max_keys: 1000, continuation_token: token) do
      {:ok, %{entries: entries, truncated: true, next_token: next}} ->
        all_keys(bucket, prefix, next, [Enum.map(entries, & &1.key) | acc])

      {:ok, %{entries: entries}} ->
        [Enum.map(entries, & &1.key) | acc] |> Enum.reverse() |> List.flatten()

      _ ->
        acc |> Enum.reverse() |> List.flatten()
    end
  end

  @doc """
  All versions of a key, newest first (markers included).
  """
  @spec list_versions(String.t(), String.t()) :: [Object.t()]
  def list_versions(bucket, key) do
    case bucket_id(bucket) do
      nil ->
        []

      id ->
        Repo.all(
          from o in Object,
            where: o.bucket_id == ^id and o.key == ^key,
            order_by: [desc: o.inserted_at, desc: o.id]
        )
    end
  end

  @doc """
  Every version in a bucket, ordered for ListVersions (key asc, newest first).
  """
  @spec list_all_versions(String.t(), pos_integer()) :: [Object.t()]
  def list_all_versions(bucket, limit \\ 1000) do
    case bucket_id(bucket) do
      nil ->
        []

      id ->
        Repo.all(
          from o in Object,
            where: o.bucket_id == ^id and o.trashed == false,
            order_by: [asc: o.key, desc: o.inserted_at, desc: o.id],
            limit: ^limit
        )
    end
  end

  defp escape_glob(s) do
    s
    |> String.codepoints()
    |> Enum.map_join(fn
      "[" -> "[[]"
      "*" -> "[*]"
      "?" -> "[?]"
      "]" -> "[]]"
      c -> c
    end)
  end

  defp paginate(contents, max_keys) do
    page = Enum.take(contents, max_keys)

    if length(contents) > max_keys do
      {page, true, List.last(page)}
    else
      {page, false, nil}
    end
  end

  # ---------- Multipart (minimal, S3-kompatibel) ----------

  @spec multipart_dir() :: String.t()
  def multipart_dir, do: Path.join(data_dir(), "__multipart__")

  @doc """
  Directory for in-flight request bodies. Lives inside `DATA_DIR` so the
  final placement is always a same-filesystem rename — never a full copy,
  even when `/tmp` is a different mount.
  """
  @spec staging_dir() :: String.t()
  def staging_dir do
    dir = Path.join(data_dir(), ".staging")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Removes staged request bodies older than `max_age_seconds` (crash
  orphans; in-flight streams are fresh). Returns `{:ok, removed_count}`.
  """
  @spec clean_staging(non_neg_integer()) :: {:ok, non_neg_integer()}
  def clean_staging(max_age_seconds \\ 24 * 3_600) do
    cutoff = System.os_time(:second) - max_age_seconds
    dir = staging_dir()

    count =
      case File.ls(dir) do
        {:ok, entries} ->
          Enum.reduce(entries, 0, fn entry, acc ->
            path = Path.join(dir, entry)

            with {:ok, %{type: :regular, mtime: mtime}} <-
                   File.stat(path, time: :posix),
                 true <- mtime < cutoff do
              File.rm(path)
              acc + 1
            else
              _ -> acc
            end
          end)

        {:error, _} ->
          0
      end

    {:ok, count}
  end

  # Upload-IDs sind 128-Bit-Zufallswerte (32 Hex-Zeichen). Alles andere wird
  # abgelehnt, damit über manipulierte IDs kein Path-Traversal möglich ist.
  @upload_id_re ~r/^[0-9a-f]{32}$/

  @spec valid_upload_id?(term()) :: boolean()
  defp valid_upload_id?(id) when is_binary(id), do: id =~ @upload_id_re
  defp valid_upload_id?(_), do: false

  @spec part_path(String.t(), integer()) :: String.t()
  defp part_path(dir, n),
    do: Path.join(dir, "part-#{String.pad_leading(to_string(n), 6, "0")}")

  @doc """
  Reads the server-side metadata of an in-flight multipart upload.
  Used to authorize part/list/complete calls against the target bucket.
  """
  @spec multipart_meta(String.t()) :: {:ok, map()} | {:error, :no_such_upload}
  def multipart_meta(upload_id) do
    with true <- valid_upload_id?(upload_id),
         dir = Path.join(multipart_dir(), upload_id),
         true <- File.dir?(dir),
         {:ok, raw} <- File.read(Path.join(dir, "meta.json")),
         {:ok, %{"bucket" => _, "key" => _} = meta} <- Jason.decode(raw) do
      {:ok, meta}
    else
      _ -> {:error, :no_such_upload}
    end
  end

  @spec create_multipart(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_content_type}
  def create_multipart(bucket, key, opts \\ []) do
    with :ok <- check_content_type(Keyword.get(opts, :content_type, "application/octet-stream")) do
      upload_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      dir = Path.join([multipart_dir(), upload_id])
      File.mkdir_p!(dir)

      meta = %{
        "bucket" => bucket,
        "key" => key,
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "content_type" => Keyword.get(opts, :content_type, "application/octet-stream")
      }

      File.write!(Path.join(dir, "meta.json"), Jason.encode!(meta))

      # Opportunistic cleanup of abandoned uploads (amortized, ~1 in 10).
      if :rand.uniform(10) == 1, do: abort_stale_multiparts()
      {:ok, upload_id}
    end
  end

  @doc """
  Lists in-flight multipart uploads for a bucket (filesystem scan of
  `__multipart__` metadata; unreadable entries are skipped).
  Returns `[%{upload_id:, key:, initiated:}]` sorted by initiation time.
  """
  @spec list_multipart_uploads(String.t()) :: [
          %{upload_id: String.t(), key: String.t(), initiated: String.t() | nil}
        ]
  def list_multipart_uploads(bucket) do
    case File.ls(multipart_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&valid_upload_id?/1)
        |> Enum.flat_map(fn upload_id ->
          case multipart_meta(upload_id) do
            {:ok, %{"bucket" => ^bucket, "key" => key} = meta} ->
              [%{upload_id: upload_id, key: key, initiated: meta["created_at"]}]

            _ ->
              []
          end
        end)
        |> Enum.sort_by(& &1.initiated)

      {:error, _} ->
        []
    end
  end

  @spec upload_part(String.t(), integer(), binary()) ::
          {:ok, String.t()} | {:error, :no_such_upload | :object_too_large}
  def upload_part(upload_id, part_number, data) when is_binary(data) do
    with :ok <- check_object_size(byte_size(data)),
         true <- valid_upload_id?(upload_id),
         dir = Path.join(multipart_dir(), upload_id),
         true <- File.dir?(dir) do
      part_path = part_path(dir, part_number)
      etag = etag_for_binary(data)
      File.write!(part_path, data)
      # ETag sidecar: CompleteMultipartUpload must not re-hash gigabytes.
      File.write!(part_path <> ".etag", etag)
      {:ok, etag}
    else
      {:error, :object_too_large} = err -> err
      _ -> {:error, :no_such_upload}
    end
  end

  @spec upload_part_from_file(String.t(), integer(), String.t()) ::
          {:ok, String.t()} | {:error, :no_such_upload | :object_too_large}
  def upload_part_from_file(upload_id, part_number, tmp_path) do
    with {:ok, %{size: size}} <- File.stat(tmp_path),
         :ok <- check_object_size(size),
         true <- valid_upload_id?(upload_id),
         dir = Path.join(multipart_dir(), upload_id),
         true <- File.dir?(dir) do
      part_path = part_path(dir, part_number)
      File.cp!(tmp_path, part_path)
      etag = etag_for_file(part_path)
      # ETag sidecar: CompleteMultipartUpload must not re-hash gigabytes.
      File.write!(part_path <> ".etag", etag)
      {:ok, etag}
    else
      {:error, :object_too_large} = err -> err
      _ -> {:error, :no_such_upload}
    end
  end

  @spec list_parts(String.t()) :: {:ok, [multipart_part()]} | {:error, :no_such_upload}
  def list_parts(upload_id) do
    with true <- valid_upload_id?(upload_id),
         dir = Path.join(multipart_dir(), upload_id),
         true <- File.dir?(dir) do
      parts =
        File.ls!(dir)
        |> Enum.filter(&(&1 =~ ~r/^part-\d{6}$/))
        |> Enum.sort()
        |> Enum.map(fn name ->
          n = name |> String.replace_prefix("part-", "") |> String.to_integer()
          path = Path.join(dir, name)
          {:ok, %{size: size}} = File.stat(path)
          %{number: n, size: size, etag: part_etag(path)}
        end)

      {:ok, parts}
    else
      _ -> {:error, :no_such_upload}
    end
  end

  @spec complete_multipart(String.t(), [integer()]) ::
          {:ok, %{etag: String.t(), path: String.t(), version_id: String.t()}}
          | {:error, :no_such_upload | :invalid_part | :object_too_large | :invalid_key}
  def complete_multipart(upload_id, ordered_part_numbers) do
    case multipart_meta(upload_id) do
      {:ok, meta} -> do_complete_multipart(upload_id, meta, ordered_part_numbers)
      # The upload directory is gone: either a retried Complete after a
      # successful one (client timeout, then retry) or a bogus ID. Replay
      # the stored receipt when the object is verifiably complete.
      {:error, :no_such_upload} -> replay_completed_upload(upload_id)
    end
  end

  defp do_complete_multipart(
         upload_id,
         %{"bucket" => bucket, "key" => key, "content_type" => ct},
         ordered_part_numbers
       ) do
    with false <- dir_key?(key),
         dir = Path.join(multipart_dir(), upload_id),
         part_paths = Enum.map(ordered_part_numbers, &part_path(dir, &1)),
         true <- part_paths != [] and Enum.all?(part_paths, &File.regular?/1),
         :ok <- check_parts_size(part_paths),
         record when not is_nil(record) <- bucket_record(bucket) do
      etags = Enum.map(part_paths, &part_etag/1)

      # S3 Multipart-ETag: md5(concat(bin(md5(part))))-N
      concat =
        etags
        |> Enum.map(&Base.decode16!(&1, case: :lower))
        |> Enum.join()

      final_etag = :crypto.hash(:md5, concat) |> Base.encode16(case: :lower)
      multipart_etag = "#{final_etag}-#{length(etags)}"

      result =
        if record.versioning == "enabled" do
          version_id = gen_version_id()
          dest = version_file(bucket, version_id)
          File.mkdir_p!(Path.dirname(dest))
          concat_parts(part_paths, dest)
          File.rm_rf!(dir)

          case insert_new_version(record.id, key, version_id, %{
                 size: total_size(part_paths),
                 etag: multipart_etag,
                 content_type: ct
               }) do
            {:ok, _} ->
              {:ok, {multipart_etag, version_id}}

            {:error, _} ->
              File.rm(dest)
              {:error, :not_found}
          end
        else
          dest = object_path(bucket, key)
          File.mkdir_p!(Path.dirname(dest))
          concat_parts(part_paths, dest)
          File.rm_rf!(dir)

          case upsert_row_for(bucket, key, %{etag: multipart_etag, content_type: ct}) do
            :ok -> {:ok, {multipart_etag, "null"}}
            {:error, _} -> {:error, :not_found}
          end
        end

      case result do
        {:ok, {etag, version_id}} ->
          completed = %{
            etag: etag,
            path: version_or_key_path(bucket, record, key),
            version_id: version_id
          }

          remember_completed_upload(upload_id, bucket, key, completed)
          {:ok, completed}

        {:error, _} = err ->
          err
      end
    else
      {:error, _} = err -> err
      false -> {:error, :invalid_part}
      true -> {:error, :invalid_key}
      nil -> {:error, :not_found}
    end
  end

  # Part ETag, preferring the sidecar written at upload time so Complete
  # never re-hashes gigabytes. Falls back to hashing for sidecar-less
  # parts (older in-flight uploads).
  defp part_etag(path) do
    case File.read(path <> ".etag") do
      {:ok, etag} ->
        etag = String.trim(etag)
        if etag =~ ~r/^[0-9a-f]{32}$/, do: etag, else: etag_for_file(path)

      _ ->
        etag_for_file(path)
    end
  end

  # Receipts of completed uploads, used to answer retried Complete calls
  # (client timeout, then retry) with the original result instead of
  # NoSuchUpload. Entries live 24h and are pruned opportunistically.
  defp completed_dir, do: Path.join(multipart_dir(), ".completed")

  defp remember_completed_upload(upload_id, bucket, key, result) do
    dir = completed_dir()
    File.mkdir_p!(dir)

    receipt = %{
      "bucket" => bucket,
      "key" => key,
      "etag" => result.etag,
      "path" => result.path,
      "version_id" => result.version_id,
      "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write(Path.join(dir, upload_id <> ".json"), Jason.encode!(receipt))
    prune_completed_uploads()
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Replays a completed upload for retried Complete calls (client timeout,
  then retry): returns the stored result when the target object still
  carries the recorded ETag. Otherwise `{:error, :no_such_upload}`.
  """
  @spec replay_completed_upload(String.t()) ::
          {:ok, %{bucket: String.t(), key: String.t(), etag: String.t(), path: String.t() | nil, version_id: String.t()}}
          | {:error, :no_such_upload}
  def replay_completed_upload(upload_id) do
    with true <- valid_upload_id?(upload_id),
         {:ok, raw} <- File.read(Path.join(completed_dir(), upload_id <> ".json")),
         {:ok, %{"bucket" => bucket, "key" => key, "etag" => etag} = receipt} <-
           Jason.decode(raw),
         {:ok, stat} <- stat_object(bucket, key),
         true <- stat.etag == etag do
      {:ok,
       %{
         bucket: bucket,
         key: key,
         etag: etag,
         path: Map.get(receipt, "path"),
         version_id: Map.get(receipt, "version_id", "null")
       }}
    else
      _ -> {:error, :no_such_upload}
    end
  end

  defp prune_completed_uploads(max_age_seconds \\ 24 * 3_600) do
    cutoff = System.os_time(:second) - max_age_seconds

    case File.ls(completed_dir()) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          path = Path.join(completed_dir(), entry)

          case File.stat(path, time: :posix) do
            {:ok, %{type: :regular, mtime: mtime}} when mtime < cutoff ->
              File.rm(path)

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp concat_parts(part_paths, dest) do
    atomic_write(dest, fn tmp ->
      {:ok, out} = File.open(tmp, [:write, :binary])

      try do
        Enum.map(part_paths, fn part_path ->
          File.stream!(part_path, 1024 * 1024) |> Enum.each(&IO.binwrite(out, &1))
        end)
      after
        File.close(out)
      end
    end)
  end

  defp total_size(part_paths) do
    Enum.reduce(part_paths, 0, fn path, acc ->
      case File.stat(path) do
        {:ok, %{size: size}} -> acc + size
        _ -> acc
      end
    end)
  end

  # Servable path for the current version (response metadata only;
  # reads go through stat_object/row_stat).
  defp version_or_key_path(bucket, record, key) do
    if record.versioning == "enabled" do
      case latest_live_row(record.id, key) do
        %Object{version_id: v} when v not in [nil, "null"] -> version_file(bucket, v)
        _ -> object_path(bucket, key)
      end
    else
      object_path(bucket, key)
    end
  end

  @spec abort_multipart(String.t()) :: :ok
  def abort_multipart(upload_id) do
    if valid_upload_id?(upload_id) do
      File.rm_rf!(Path.join(multipart_dir(), upload_id))
    end

    :ok
  end

  @doc """
  Reconciles a bucket's rows with its files:

  - files without a row are adopted (legacy data, crash orphans);
    legacy sidecars contribute content type/ETag when still valid,
    then are removed;
  - rows without a file or marker are pruned.

  Returns `{:ok, %{adopted: n, pruned: n, usage_bytes: n, object_count: n}}`
  with exact database aggregates.
  """
  @spec reconcile_bucket(String.t()) :: {:ok, map()} | {:error, :no_such_bucket}
  def reconcile_bucket(bucket) do
    with id when not is_nil(id) <- bucket_id(bucket) do
      base = bucket_path(bucket)

      marker_paths =
        base
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.filter(&marker_file?/1)

      adopted_files =
        Enum.count(stored_files(bucket), fn path ->
          adopt_path(id, bucket, Path.relative_to(path, base), path)
        end)

      adopted_markers =
        Enum.count(marker_paths, fn path ->
          rel = Path.relative_to(path, base)
          adopt_path(id, bucket, Path.dirname(rel) <> "/", path)
        end)

      adopted = adopted_files + adopted_markers

      pruned =
        Repo.all(from o in Object, where: o.bucket_id == ^id)
        |> Enum.group_by(& &1.key)
        |> Enum.count(fn {key, versions} ->
          if key_has_file?(bucket, base, key, versions) do
            false
          else
            Repo.delete_all(from o in Object, where: o.bucket_id == ^id and o.key == ^key)
            true
          end
        end)

      gc_version_files(bucket, id)

      usage = Repo.aggregate(from(o in Object, where: o.bucket_id == ^id), :sum, :size) || 0
      count = Repo.aggregate(from(o in Object, where: o.bucket_id == ^id), :count)

      {:ok, %{adopted: adopted, pruned: pruned, usage_bytes: usage, object_count: count}}
    else
      _ -> {:error, :no_such_bucket}
    end
  end

  @doc """
  Verifies stored content against the objects table without changing
  anything. Checks every non-deleted row: file presence, size and (for
  single-part uploads) the MD5 etag. Multipart composite etags
  (`<md5>-<n>`) and folder markers only get presence+size checks.

  Returns `%{checked: n, missing: [...], size_mismatch: [...],
  etag_mismatch: [...]}` with `{key, version_id}` tuples.
  """
  @spec verify_bucket_integrity(String.t()) ::
          {:ok,
           %{
             checked: non_neg_integer(),
             missing: list(),
             size_mismatch: list(),
             etag_mismatch: list()
           }}
          | {:error, :no_such_bucket}
  def verify_bucket_integrity(bucket) do
    with id when not is_nil(id) <- bucket_id(bucket) do
      rows = Repo.all(from o in Object, where: o.bucket_id == ^id and o.deleted == false)

      report =
        Enum.reduce(
          rows,
          %{checked: 0, missing: [], size_mismatch: [], etag_mismatch: []},
          fn row, acc ->
            acc = %{acc | checked: acc.checked + 1}

            case row_stat(bucket, row) do
              {:ok, %{path: path}} ->
                check_row_file(path, row, acc)

              {:error, :not_found} ->
                %{acc | missing: [{row.key, row.version_id} | acc.missing]}
            end
          end
        )

      {:ok,
       %{
         report
         | missing: Enum.reverse(report.missing),
           size_mismatch: Enum.reverse(report.size_mismatch),
           etag_mismatch: Enum.reverse(report.etag_mismatch)
       }}
    else
      _ -> {:error, :no_such_bucket}
    end
  end

  defp check_row_file(path, row, acc) do
    with {:ok, %{size: size}} <- File.stat(path) do
      acc =
        if size == row.size or dir_key?(row.key) do
          acc
        else
          %{acc | size_mismatch: [{row.key, row.version_id} | acc.size_mismatch]}
        end

      if not dir_key?(row.key) and single_part_etag?(row.etag) and size == row.size and
           etag_for_file(path) != row.etag do
        %{acc | etag_mismatch: [{row.key, row.version_id} | acc.etag_mismatch]}
      else
        acc
      end
    else
      _ -> %{acc | missing: [{row.key, row.version_id} | acc.missing]}
    end
  end

  defp single_part_etag?(etag),
    do: is_binary(etag) and etag != "" and not String.contains?(etag, "-")

  defp key_has_file?(bucket, base, key, versions) do
    cond do
      dir_key?(key) ->
        case String.trim_trailing(key, "/") do
          "" -> false
          trimmed -> marker_file?(Path.join([base, trimmed, @dir_marker]))
        end

      Enum.any?(versions, &(&1.version_id in [nil, "null"])) ->
        # Keys are stored mapped; reverse exactly what key_to_path/1 does.
        object_path(bucket, key) |> File.regular?()

      true ->
        Enum.any?(versions, fn v ->
          v.version_id not in [nil, "null"] and
            version_file(bucket, v.version_id) |> File.regular?()
        end)
    end
  rescue
    _ -> false
  end

  # Drops version content files that no row references anymore (crash
  # orphans), unless recently written (in-flight completes).
  defp gc_version_files(bucket, bucket_id, max_age_seconds \\ 3600) do
    cutoff = System.os_time(:second) - max_age_seconds
    dir = Path.join([data_dir(), "__versions__", sanitize_bucket!(bucket)])

    referenced =
      Repo.all(from o in Object, where: o.bucket_id == ^bucket_id, select: o.version_id)
      |> MapSet.new()

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          path = Path.join(dir, entry)

          with false <- MapSet.member?(referenced, entry),
               {:ok, %{type: :regular, mtime: mtime}} <- File.stat(path, time: :posix),
               true <- mtime < cutoff do
            File.rm(path)
          else
            _ -> :ok
          end
        end)

      {:error, _} ->
        :ok
    end
  end

  # Ensures a row exists for bytes found on disk (legacy data, crash
  # orphans). Legacy sidecars contribute content type/ETag when still
  # valid, then are removed. Returns true when a row was created.
  defp adopt_path(bucket_id, bucket, key, path) do
    if Repo.get_by(Object, bucket_id: bucket_id, key: key) do
      consume_sidecar(path)
      false
    else
      {etag, content_type} = sidecar_or_fresh(bucket, path, key)

      upsert_row(bucket_id, key, %{
        size: file_size_for(path, key),
        etag: etag,
        content_type: content_type
      })

      consume_sidecar(path)
      true
    end
  end

  defp file_size_for(path, key) do
    if dir_key?(key) do
      0
    else
      case File.stat(path) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end
    end
  end

  defp sidecar_or_fresh(_bucket, path, key) do
    sidecar = path <> @meta_suffix

    with {:ok, raw} <- File.read(sidecar),
         {:ok, %{"etag" => e, "size" => s, "mtime" => m} = decoded} <- Jason.decode(raw),
         {:ok, %{size: ^s, mtime: ^m}} <- File.stat(path, time: :posix),
         true <- is_binary(e) do
      content_type =
        case decoded do
          %{"content_type" => ct} when is_binary(ct) -> ct
          _ -> nil
        end

      {e, content_type}
    else
      _ ->
        if dir_key?(key) do
          {@empty_etag, nil}
        else
          {etag_for_file(path), nil}
        end
    end
  end

  # Removes a legacy sidecar (stale once rows are authoritative).
  defp consume_sidecar(path) do
    sidecar = path <> @meta_suffix
    if File.regular?(sidecar), do: File.rm(sidecar)
    :ok
  end

  @doc """
  Deletes in-flight multipart uploads older than `max_age_seconds`
  (default: 24h), judged by directory mtime. Only well-formed upload
  directories are touched. Returns `{:ok, removed_count}`.
  """
  @spec abort_stale_multiparts(non_neg_integer()) :: {:ok, non_neg_integer()}
  def abort_stale_multiparts(max_age_seconds \\ 24 * 3600) do
    cutoff = System.os_time(:second) - max_age_seconds

    count =
      case File.ls(multipart_dir()) do
        {:ok, entries} ->
          Enum.reduce(entries, 0, fn entry, acc ->
            path = Path.join(multipart_dir(), entry)

            if stale_upload_dir?(path, cutoff) do
              File.rm_rf!(path)
              acc + 1
            else
              acc
            end
          end)

        {:error, _} ->
          0
      end

    {:ok, count}
  end

  defp stale_upload_dir?(path, cutoff) do
    with true <- valid_upload_id?(Path.basename(path)),
         {:ok, %{type: :directory, mtime: mtime}} <- File.stat(path, time: :posix) do
      mtime < cutoff
    else
      _ -> false
    end
  end
end
