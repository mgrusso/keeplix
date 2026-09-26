defmodule Keeplix.MultipartCompleteTest do
  @moduledoc """
  Multipart completion: ETag sidecars avoid re-hashing, and retried
  Complete calls replay the stored receipt instead of NoSuchUpload.
  """
  use Keeplix.DataCase

  alias Keeplix.{Accounts, Buckets, Storage}

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "mpc-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "mpc-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, user)
    on_exit(fn -> Storage.delete_bucket(bucket) end)
    {:ok, bucket: bucket}
  end

  defp part_path(upload_id, n) do
    Path.join([
      Storage.multipart_dir(),
      upload_id,
      "part-#{String.pad_leading(to_string(n), 6, "0")}"
    ])
  end

  test "upload_part writes an etag sidecar; complete uses it", %{bucket: bucket} do
    {:ok, id} = Storage.create_multipart(bucket, "big.bin")
    {:ok, etag1} = Storage.upload_part(id, 1, "hello ")
    {:ok, etag2} = Storage.upload_part(id, 2, "world")

    assert File.read!(part_path(id, 1) <> ".etag") == etag1
    assert File.read!(part_path(id, 2) <> ".etag") == etag2

    assert {:ok, %{etag: etag}} = Storage.complete_multipart(id, [1, 2])
    assert String.ends_with?(etag, "-2")
    assert {:ok, %{size: 11}} = Storage.stat_object(bucket, "big.bin")
  end

  test "complete falls back to hashing without sidecars", %{bucket: bucket} do
    {:ok, id} = Storage.create_multipart(bucket, "legacy.bin")
    {:ok, _} = Storage.upload_part(id, 1, "legacy-data")
    File.rm!(part_path(id, 1) <> ".etag")

    assert {:ok, %{etag: etag}} = Storage.complete_multipart(id, [1])
    assert String.ends_with?(etag, "-1")
    assert {:ok, %{size: 11}} = Storage.stat_object(bucket, "legacy.bin")
  end

  test "retried complete replays the receipt", %{bucket: bucket} do
    {:ok, id} = Storage.create_multipart(bucket, "retry.bin")
    {:ok, _} = Storage.upload_part(id, 1, "retry-me")

    assert {:ok, first} = Storage.complete_multipart(id, [1])
    # Upload directory is gone, but the retry succeeds with the same result.
    assert {:ok, second} = Storage.complete_multipart(id, [1])
    assert second.etag == first.etag
    assert second.version_id == first.version_id
  end

  test "replay after overwrite returns no_such_upload", %{bucket: bucket} do
    {:ok, id} = Storage.create_multipart(bucket, "over.bin")
    {:ok, _} = Storage.upload_part(id, 1, "version-one")
    assert {:ok, _} = Storage.complete_multipart(id, [1])

    {:ok, _} = Storage.put_object(bucket, "over.bin", "version-two!")
    assert {:error, :no_such_upload} = Storage.complete_multipart(id, [1])
  end

  test "unknown upload ids still fail", %{bucket: _bucket} do
    assert {:error, :no_such_upload} =
             Storage.complete_multipart("0123456789abcdef0123456789abcdef", [1])
  end
end
