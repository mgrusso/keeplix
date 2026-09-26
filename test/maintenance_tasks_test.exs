defmodule Keeplix.MaintenanceTasksTest do
  @moduledoc """
  Integrity verification (B3): clean tree passes, damage is reported.
  """
  use Keeplix.DataCase

  alias Keeplix.{Accounts, Buckets, Storage}

  setup do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "maint-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "maint-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, bucket: bucket}
  end

  test "clean bucket verifies without findings", %{bucket: bucket} do
    assert {:ok, _} = Storage.put_object(bucket, "a.txt", "hello")
    assert {:ok, _} = Storage.put_object(bucket, "sub/b.bin", :crypto.strong_rand_bytes(1024))

    assert {:ok, report} = Storage.verify_bucket_integrity(bucket)
    assert report.checked == 2
    assert report.missing == []
    assert report.size_mismatch == []
    assert report.etag_mismatch == []
  end

  test "missing file is reported", %{bucket: bucket} do
    assert {:ok, _} = Storage.put_object(bucket, "gone.txt", "data")
    File.rm!(Storage.object_path(bucket, "gone.txt"))

    assert {:ok, report} = Storage.verify_bucket_integrity(bucket)
    assert report.checked == 1
    assert [{"gone.txt", _}] = report.missing
  end

  test "corrupted content is reported", %{bucket: bucket} do
    assert {:ok, _} = Storage.put_object(bucket, "rot.txt", "data!!")
    File.write!(Storage.object_path(bucket, "rot.txt"), "tampered-content!!")

    assert {:ok, report} = Storage.verify_bucket_integrity(bucket)
    assert report.checked == 1
    assert report.missing == []
    assert [{"rot.txt", _}] = report.size_mismatch
    # Same-size corruption trips the etag check instead.
    File.write!(Storage.object_path(bucket, "rot.txt"), "DATA!!")
    assert {:ok, report2} = Storage.verify_bucket_integrity(bucket)
    assert [{"rot.txt", _}] = report2.etag_mismatch
  end

  test "unknown bucket errors",
    do: assert({:error, :no_such_bucket} = Storage.verify_bucket_integrity("nope-xyz"))
end
