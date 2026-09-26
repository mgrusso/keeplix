defmodule Keeplix.StorageObjectsTest do
  @moduledoc """
  Object metadata lives in the database; files stay on disk (Phase B).
  """
  use Keeplix.DataCase

  alias Keeplix.{Buckets, Repo, Storage}
  alias Keeplix.Storage.Object

  setup do
    {:ok, user} =
      Keeplix.Accounts.create_user(%{
        username: "obj-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "obj-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, user)
    on_exit(fn -> Storage.delete_bucket(bucket) end)
    {:ok, bucket: bucket}
  end

  defp row!(bucket, key) do
    b = Buckets.get_bucket(bucket)
    Repo.get_by!(Object, bucket_id: b.id, key: key)
  end

  test "put persists a row; stat reads it", %{bucket: bucket} do
    {:ok, stat} = Storage.put_object(bucket, "f.txt", "hello", content_type: "text/plain")

    row = row!(bucket, "f.txt")
    assert row.size == 5
    assert row.etag == Storage.etag_for_binary("hello")
    assert row.content_type == "text/plain"
    assert stat.etag == row.etag
    assert Storage.get_content_type(bucket, "f.txt") == "text/plain"
  end

  test "overwrite replaces the row", %{bucket: bucket} do
    {:ok, _} = Storage.put_object(bucket, "f.txt", "hello")
    {:ok, stat} = Storage.put_object(bucket, "f.txt", "hello world!")

    assert stat.size == 12
    assert Repo.aggregate(from(o in Object), :count) == 1
  end

  test "delete moves to trash; purge removes file and row", %{bucket: bucket} do
    {:ok, _} = Storage.put_object(bucket, "f.txt", "hello")
    :ok = Storage.delete_object(bucket, "f.txt")

    assert {:error, :not_found} = Storage.stat_object(bucket, "f.txt")
    assert {:ok, [%{key: "f.txt"}]} = Storage.list_trash(bucket)
    assert File.regular?(Storage.object_path(bucket, "f.txt"))

    assert :ok = Storage.restore_object(bucket, "f.txt")
    assert {:ok, %{size: 5}} = Storage.stat_object(bucket, "f.txt")
    assert {:ok, []} = Storage.list_trash(bucket)

    :ok = Storage.delete_object(bucket, "f.txt")
    assert :ok = Storage.purge_object(bucket, "f.txt")
    assert Repo.aggregate(from(o in Object), :count) == 0
    refute File.exists?(Storage.object_path(bucket, "f.txt"))
  end

  test "restore fails when the key was reclaimed", %{bucket: bucket} do
    {:ok, _} = Storage.put_object(bucket, "f.txt", "hello")
    :ok = Storage.delete_object(bucket, "f.txt")

    {:ok, _} = bucket |> Buckets.get_bucket() |> Buckets.set_versioning("enabled")
    {:ok, _} = Storage.put_object(bucket, "f.txt", "new")

    assert {:error, :key_exists} = Storage.restore_object(bucket, "f.txt")
    assert {:ok, %{size: 3}} = Storage.stat_object(bucket, "f.txt")
  end

  test "empty trash purges everything", %{bucket: bucket} do
    {:ok, _} = Storage.put_object(bucket, "a.txt", "a")
    {:ok, _} = Storage.put_object(bucket, "b.txt", "b")
    :ok = Storage.delete_object(bucket, "a.txt")
    :ok = Storage.delete_object(bucket, "b.txt")

    assert {:ok, 2} = Storage.empty_trash(bucket)
    assert {:ok, []} = Storage.list_trash(bucket)
    assert Repo.aggregate(from(o in Object), :count) == 0
  end

  test "row without file reads as missing", %{bucket: bucket} do
    {:ok, _} = Storage.put_object(bucket, "f.txt", "hello")
    File.rm!(Storage.object_path(bucket, "f.txt"))

    assert {:error, :not_found} = Storage.stat_object(bucket, "f.txt")
  end

  test "prefix filtering is case-sensitive and glob-safe", %{bucket: bucket} do
    for key <- ["Abc", "abc", "a%c", "a_c", "a[b", "abd"] do
      {:ok, _} = Storage.put_object(bucket, key, "x")
    end

    assert {:ok, %{entries: entries}} = Storage.list_objects(bucket, prefix: "a")
    # Byte order: "%" (37) < "[" (91) < "_" (95) < letters.
    assert Enum.map(entries, & &1.key) == ["a%c", "a[b", "a_c", "abc", "abd"]

    assert {:ok, %{entries: [%{key: "Abc"}]}} = Storage.list_objects(bucket, prefix: "A")
    assert {:ok, %{entries: [%{key: "a%c"}]}} = Storage.list_objects(bucket, prefix: "a%")
    assert {:ok, %{entries: [%{key: "a[b"}]}} = Storage.list_objects(bucket, prefix: "a[")
  end

  test "continuation tokens paginate in the database", %{bucket: bucket} do
    for n <- 1..5 do
      {:ok, _} = Storage.put_object(bucket, "k#{n}", "x")
    end

    assert {:ok, %{entries: [%{key: "k1"}, %{key: "k2"}], truncated: true, next_token: "k2"}} =
             Storage.list_objects(bucket, max_keys: 2)

    assert {:ok, %{entries: [%{key: "k3"}, %{key: "k4"}], truncated: true, next_token: "k4"}} =
             Storage.list_objects(bucket, max_keys: 2, continuation_token: "k2")

    assert {:ok, %{entries: [%{key: "k5"}], truncated: false}} =
             Storage.list_objects(bucket, max_keys: 2, continuation_token: "k4")
  end

  test "markers are rows: flat listing shows them, delimited groups them", %{bucket: bucket} do
    {:ok, _} = Storage.put_object(bucket, "d/", "ignored")

    assert {:ok, %{entries: [%{key: "d/", size: 0}]}} = Storage.list_objects(bucket)

    assert {:ok, %{entries: [], prefixes: ["d/"]}} =
             Storage.list_objects(bucket, delimiter: "/")
  end

  test "reconcile adopts legacy files and sidecars, prunes ghosts", %{bucket: bucket} do
    # Legacy layout, bypassing the row layer.
    File.mkdir_p!(Path.join(Storage.bucket_path(bucket), "legacy"))
    File.write!(Storage.object_path(bucket, "legacy/old.txt"), "legacy-data")

    legacy_meta = Storage.object_path(bucket, "legacy/old.txt") <> ".keeplix-meta"
    mtime = File.stat!(Storage.object_path(bucket, "legacy/old.txt"), time: :posix).mtime

    File.write!(
      legacy_meta,
      Jason.encode!(%{content_type: "text/plain", etag: "keepme", size: 11, mtime: mtime})
    )

    # Orphan file without any metadata.
    File.write!(Storage.object_path(bucket, "orphan.bin"), "123456")

    # Ghost row without a file.
    b = Buckets.get_bucket(bucket)

    %Object{bucket_id: b.id}
    |> Object.changeset(%{key: "ghost.txt", size: 1, etag: "x"})
    |> Repo.insert!()

    assert {:ok, stats} = Storage.reconcile_bucket(bucket)
    assert stats.adopted == 2
    assert stats.pruned == 1
    assert stats.usage_bytes == 17
    assert stats.object_count == 2

    # Sidecar values win when still valid; sidecar is gone afterwards.
    assert {:ok, %{etag: "keepme"}} = Storage.stat_object(bucket, "legacy/old.txt")
    assert Storage.get_content_type(bucket, "legacy/old.txt") == "text/plain"
    refute File.exists?(legacy_meta)

    # Aggregates match the database.
    assert %{bytes: 17, count: 2} = Buckets.usage(Buckets.get_bucket(bucket))
  end
end
