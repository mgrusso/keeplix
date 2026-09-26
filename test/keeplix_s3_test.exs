defmodule Keeplix.S3Test do
  use Keeplix.DataCase

  alias Keeplix.{Accounts, Buckets, Storage}

  test "user, bucket, object, grants" do
    bucket_name = "test-bucket-#{System.unique_integer([:positive])}"
    alice = "alice-#{System.unique_integer([:positive])}"
    bob_name = "bob-#{System.unique_integer([:positive])}"

    {:ok, admin} =
      Accounts.create_user(%{username: alice, password: "secret123", role: "admin"})

    {:ok, bob} = Accounts.create_user(%{username: bob_name, password: "secret123", role: "user"})

    on_exit(fn -> Storage.delete_bucket(bucket_name) end)

    {:ok, bucket} = Buckets.create_bucket(bucket_name, admin)
    assert bucket.name == bucket_name

    assert Buckets.can_admin?(admin, bucket)
    refute Buckets.can_read?(bob, bucket)

    {:ok, _} = Buckets.grant_permission(bucket.id, "read", user_id: bob.id, group_id: nil)
    bob_fresh = Accounts.get_user!(bob.id)
    bucket_fresh = Buckets.get_bucket(bucket_name)
    assert Buckets.can_read?(bob_fresh, bucket_fresh)
    refute Buckets.can_write?(bob_fresh, bucket_fresh)

    {:ok, stat} =
      Storage.put_object(bucket_name, "hallo/welt.txt", "hello", content_type: "text/plain")

    assert stat.size == 5
    assert {:ok, _} = Storage.stat_object(bucket_name, "hallo/welt.txt")

    assert {:ok, %{entries: [_], prefixes: _}} =
             Storage.list_objects(bucket_name, prefix: "hallo/")

    assert {:ok, %{entries: _, prefixes: [_]}} =
             Storage.list_objects(bucket_name, delimiter: "/")
  end

  test "create and delete access keys" do
    {:ok, user} = Accounts.create_user(%{username: "carol", password: "secret1234", role: "user"})

    {:ok, record, %{access_key_id: akid, secret: secret}} =
      Accounts.create_access_key(user, "test")

    assert is_binary(akid) and is_binary(secret)
    assert Accounts.get_key_by_access_id(akid).id == record.id
    {:ok, _} = Accounts.delete_access_key(record.id)
    assert Accounts.get_key_by_access_id(akid) == nil
  end

  test "owner_id and key user_id are not mass-assignable" do
    {:ok, owner} =
      Accounts.create_user(%{username: "owner-1", password: "secret1234", role: "user"})

    {:ok, other} =
      Accounts.create_user(%{username: "owner-2", password: "secret1234", role: "user"})

    {:ok, bucket} = Buckets.create_bucket("owned-#{System.unique_integer([:positive])}", owner)

    # update_bucket quietly ignores owner_id.
    {:ok, same} = Buckets.update_bucket(bucket, %{owner_id: other.id, quota_bytes: nil})
    assert same.owner_id == owner.id

    # Direct changesets drop the programmatic ids as well.
    bucket_cs =
      Keeplix.Buckets.Bucket.changeset(%Keeplix.Buckets.Bucket{}, %{name: "x", owner_id: other.id})

    refute Ecto.Changeset.get_change(bucket_cs, :owner_id)

    key_cs =
      Accounts.AccessKey.changeset(%Accounts.AccessKey{}, %{
        access_key_id: "X",
        secret_enc: "Y",
        user_id: other.id
      })

    refute Ecto.Changeset.get_change(key_cs, :user_id)
  end
end
