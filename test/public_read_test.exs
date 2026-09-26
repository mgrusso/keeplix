defmodule KeeplixWeb.PublicReadTest do
  @moduledoc """
  Public-read buckets: anonymous downloads work, listings and writes
  stay credentialed.
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "pub-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "pub-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    {:ok, _, creds} = Accounts.create_access_key(owner, "pub")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    put = signed_request(conn, "PUT", "/#{bucket}/f.txt", body: "public-bytes", creds: creds)
    assert put.status == 200

    {:ok, conn: conn, bucket: bucket, creds: creds}
  end

  defp anon(conn, method, path) do
    c = if conn.state == :unset, do: conn, else: Phoenix.ConnTest.build_conn()

    Phoenix.ConnTest.dispatch(
      Map.put(c, :host, "example.com"),
      KeeplixWeb.Endpoint,
      method,
      path,
      nil
    )
  end

  test "anonymous GET on private bucket is denied", %{conn: conn, bucket: bucket} do
    assert anon(conn, :get, "/#{bucket}/f.txt").status == 403
    assert anon(conn, :head, "/#{bucket}/f.txt").status == 403
  end

  test "anonymous listing stays denied on public buckets", %{
    conn: conn,
    bucket: bucket,
    creds: creds
  } do
    {:ok, _} = Buckets.update_bucket(Buckets.get_bucket(bucket), %{acl: "public-read"})

    assert anon(conn, :get, "/#{bucket}").status == 403
    # Anonymous root hits the web UI redirect, never a bucket listing.
    assert anon(conn, :get, "/").status == 302

    # Writes stay credentialed, too.
    assert anon(conn, :put, "/#{bucket}/evil.txt").status != 200
    assert anon(conn, :delete, "/#{bucket}/f.txt").status != 200

    # ...while credentialed access is unaffected.
    authed = signed_request(conn, "GET", "/#{bucket}/f.txt", creds: creds)
    assert authed.status == 200
    assert authed.resp_body == "public-bytes"
  end

  test "anonymous GET/HEAD work on public-read buckets", %{conn: conn, bucket: bucket} do
    {:ok, _} = Buckets.update_bucket(Buckets.get_bucket(bucket), %{acl: "public-read"})

    get = anon(conn, :get, "/#{bucket}/f.txt")
    assert get.status == 200
    assert get.resp_body == "public-bytes"

    head = anon(conn, :head, "/#{bucket}/f.txt")
    assert head.status == 200

    missing = anon(conn, :get, "/#{bucket}/nope.txt")
    assert missing.status == 404
  end

  test "public-read via S3 canned ACL header", %{conn: conn, bucket: bucket, creds: creds} do
    put =
      signed_request(conn, "PUT", "/#{bucket}",
        query: "acl=",
        headers: [{"x-amz-acl", "public-read"}],
        creds: creds
      )

    assert put.status == 200
    assert Buckets.public_read?(Buckets.get_bucket(bucket))

    assert anon(conn, :get, "/#{bucket}/f.txt").status == 200
  end
end
