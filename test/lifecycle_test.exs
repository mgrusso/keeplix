defmodule Keeplix.LifecycleTest do
  @moduledoc """
  Lifecycle configuration and expiration (item 3c).
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing

  alias Keeplix.{Accounts, Buckets, Storage}

  @config """
  <LifecycleConfiguration>
    <Rule>
      <ID>tmp-expire</ID>
      <Status>Enabled</Status>
      <Filter><Prefix>tmp/</Prefix></Filter>
      <Expiration><Days>30</Days></Expiration>
    </Rule>
  </LifecycleConfiguration>
  """

  setup %{conn: conn} do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "lc-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "lc-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    {:ok, _, creds} = Accounts.create_access_key(owner, "lc")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, conn: conn, bucket: bucket, creds: creds}
  end

  test "lifecycle roundtrip over S3", %{conn: conn, bucket: bucket, creds: creds} do
    put =
      signed_request(conn, "PUT", "/#{bucket}", query: "lifecycle=", body: @config, creds: creds)

    assert put.status == 200

    get = signed_request(conn, "GET", "/#{bucket}", query: "lifecycle=", creds: creds)
    assert get.status == 200
    assert get.resp_body =~ "tmp-expire"
    assert get.resp_body =~ "<Days>30</Days>"

    del = signed_request(conn, "DELETE", "/#{bucket}", query: "lifecycle=", creds: creds)
    assert del.status == 200

    gone = signed_request(conn, "GET", "/#{bucket}", query: "lifecycle=", creds: creds)
    assert gone.status == 404
  end

  test "invalid lifecycle rejected", %{conn: conn, bucket: bucket, creds: creds} do
    bad =
      signed_request(conn, "PUT", "/#{bucket}",
        query: "lifecycle=",
        body: "<LifecycleConfiguration/>",
        creds: creds
      )

    assert bad.status == 400
  end

  test "expiration deletes old prefixed objects", %{bucket: bucket} do
    {:ok, bucket_record} = Buckets.get_bucket(bucket) |> then(&{:ok, &1})

    {:ok, _} =
      Buckets.put_lifecycle_config(bucket_record, [
        %{"id" => "r", "status" => "Enabled", "prefix" => "tmp/", "days" => 30}
      ])

    {:ok, _} = Storage.put_object(bucket, "tmp/old.txt", "old")
    {:ok, _} = Storage.put_object(bucket, "keep.txt", "keep")

    # Backdate the tmp object beyond the expiration window.
    past = DateTime.utc_now() |> DateTime.add(-31 * 86_400, :second)
    b = Buckets.get_bucket(bucket)
    import Ecto.Query

    Keeplix.Repo.update_all(
      from(o in Keeplix.Storage.Object, where: o.bucket_id == ^b.id),
      set: [updated_at: past]
    )

    # keep.txt is fresh again; only tmp/old.txt must expire.
    {:ok, _} = Storage.put_object(bucket, "keep.txt", "keep")

    assert {:ok, %{expired: 1}} = Storage.apply_lifecycle(bucket)
    refute Storage.object_exists?(bucket, "tmp/old.txt")
    assert Storage.object_exists?(bucket, "keep.txt")
  end
end
