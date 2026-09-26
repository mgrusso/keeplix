defmodule KeeplixWeb.AclTest do
  @moduledoc """
  Canned ACLs: stored, reported, applied on writes (item 3d).
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "acl-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "acl-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    {:ok, _, creds} = Accounts.create_access_key(owner, "acl")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    put = signed_request(conn, "PUT", "/#{bucket}/f.txt", body: "x", creds: creds)
    assert put.status == 200

    {:ok, conn: conn, bucket: bucket, creds: creds, owner: owner}
  end

  test "object ACL defaults to private, PUT ?acl changes it", %{
    conn: conn,
    bucket: bucket,
    creds: creds,
    owner: owner
  } do
    get = signed_request(conn, "GET", "/#{bucket}/f.txt", query: "acl=", creds: creds)
    assert get.status == 200
    assert get.resp_body =~ "AccessControlPolicy"
    assert get.resp_body =~ owner.username
    assert get.resp_body =~ "FULL_CONTROL"
    refute get.resp_body =~ "AllUsers"

    put =
      signed_request(conn, "PUT", "/#{bucket}/f.txt",
        query: "acl=",
        headers: [{"x-amz-acl", "public-read"}],
        creds: creds
      )

    assert put.status == 200

    get2 = signed_request(conn, "GET", "/#{bucket}/f.txt", query: "acl=", creds: creds)
    assert get2.resp_body =~ "AllUsers"
  end

  test "bucket ACL roundtrip", %{conn: conn, bucket: bucket, creds: creds} do
    put =
      signed_request(conn, "PUT", "/#{bucket}",
        query: "acl=",
        headers: [{"x-amz-acl", "bucket-owner-full-control"}],
        creds: creds
      )

    assert put.status == 200

    get = signed_request(conn, "GET", "/#{bucket}", query: "acl=", creds: creds)
    assert get.resp_body =~ "FULL_CONTROL"
  end

  test "invalid ACL rejected", %{conn: conn, bucket: bucket, creds: creds} do
    bad =
      signed_request(conn, "PUT", "/#{bucket}/f.txt",
        query: "acl=",
        headers: [{"x-amz-acl", "everyone-can-write"}],
        creds: creds
      )

    assert bad.status == 400

    bad_put =
      signed_request(conn, "PUT", "/#{bucket}/new.txt",
        body: "x",
        headers: [{"x-amz-acl", "bogus"}],
        creds: creds
      )

    assert bad_put.status == 400
    # Nothing stored on rejection.
    assert {:error, :not_found} = Storage.stat_object(bucket, "new.txt")
  end

  test "x-amz-acl on PUT object sticks", %{conn: conn, bucket: bucket, creds: creds} do
    put =
      signed_request(conn, "PUT", "/#{bucket}/a.txt",
        body: "x",
        headers: [{"x-amz-acl", "authenticated-read"}],
        creds: creds
      )

    assert put.status == 200
    assert {:ok, "authenticated-read"} = Storage.get_object_acl(bucket, "a.txt")
  end
end
