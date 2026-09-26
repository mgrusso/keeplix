defmodule KeeplixWeb.S3AuthzTest do
  @moduledoc """
  Authorization and replay-protection tests for the S3 API (P0):

  - HeadObject / UploadPart / CompleteMultipart / ListParts require
    bucket permissions (previously unchecked)
  - header signatures carry a freshness window (no indefinite replays)
  - presigned URLs honor expiry and a 7-day maximum lifetime
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    Keeplix.RateLimit.reset_all()
    owner = create_user("authz-owner")
    attacker = create_user("authz-attacker")
    bucket = "authz-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    {:ok, _, owner_creds} = Accounts.create_access_key(owner, "owner")
    {:ok, _, attacker_creds} = Accounts.create_access_key(attacker, "attacker")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok,
     conn: conn,
     owner: owner,
     attacker: attacker,
     bucket: bucket,
     owner_creds: owner_creds,
     attacker_creds: attacker_creds}
  end

  defp create_user(prefix) do
    {:ok, user} =
      Accounts.create_user(%{
        username: "#{prefix}-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    user
  end

  defp old_amz_date do
    DateTime.utc_now()
    |> DateTime.add(-3600, :second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  # ---------- HeadObject ----------

  test "HeadObject requires read permission", %{
    conn: conn,
    bucket: bucket,
    attacker_creds: attacker_creds
  } do
    :ok = Storage.put_object(bucket, "secret.txt", "data") |> elem(0)

    conn = signed_request(conn, "HEAD", "/#{bucket}/secret.txt", creds: attacker_creds)
    assert conn.status == 403
  end

  test "HeadObject succeeds with read permission", %{
    conn: conn,
    bucket: bucket,
    attacker: attacker,
    attacker_creds: attacker_creds
  } do
    :ok = Storage.put_object(bucket, "secret.txt", "data") |> elem(0)
    b = Buckets.get_bucket(bucket)
    {:ok, _} = Buckets.grant_permission(b.id, "read", user_id: attacker.id, group_id: nil)

    conn = signed_request(conn, "HEAD", "/#{bucket}/secret.txt", creds: attacker_creds)
    assert conn.status == 200
  end

  # ---------- multipart ----------

  defp initiate_upload(conn, bucket, key, creds) do
    conn = signed_request(conn, "POST", "/#{bucket}/#{key}", query: "uploads=", creds: creds)
    assert conn.status == 200
    [_, upload_id] = Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, conn.resp_body)
    upload_id
  end

  test "UploadPart requires write permission", %{
    conn: conn,
    bucket: bucket,
    owner_creds: owner_creds,
    attacker_creds: attacker_creds
  } do
    upload_id = initiate_upload(conn, bucket, "big.bin", owner_creds)

    denied =
      signed_request(conn, "PUT", "/#{bucket}/big.bin",
        query: "partNumber=1&uploadId=#{upload_id}",
        body: "part-one",
        creds: attacker_creds
      )

    assert denied.status == 403

    allowed =
      signed_request(conn, "PUT", "/#{bucket}/big.bin",
        query: "partNumber=1&uploadId=#{upload_id}",
        body: "part-one",
        creds: owner_creds
      )

    assert allowed.status == 200
    assert get_resp_header(allowed, "etag") != []
  end

  test "CompleteMultipart requires write permission and writes nothing otherwise", %{
    conn: conn,
    bucket: bucket,
    owner_creds: owner_creds,
    attacker_creds: attacker_creds
  } do
    upload_id = initiate_upload(conn, bucket, "big.bin", owner_creds)

    ok =
      signed_request(conn, "PUT", "/#{bucket}/big.bin",
        query: "partNumber=1&uploadId=#{upload_id}",
        body: "part-one",
        creds: owner_creds
      )

    assert ok.status == 200
    [_, etag] = Regex.run(~r/^"([^"]+)"$/, List.first(get_resp_header(ok, "etag")))

    body =
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"#{etag}\"</ETag></Part></CompleteMultipartUpload>"

    denied =
      signed_request(conn, "POST", "/#{bucket}/big.bin",
        query: "uploadId=#{upload_id}",
        body: body,
        creds: attacker_creds
      )

    assert denied.status == 403
    refute Storage.object_exists?(bucket, "big.bin")

    allowed =
      signed_request(conn, "POST", "/#{bucket}/big.bin",
        query: "uploadId=#{upload_id}",
        body: body,
        creds: owner_creds
      )

    assert allowed.status == 200
    assert Storage.object_exists?(bucket, "big.bin")
  end

  test "ListParts requires read permission", %{
    conn: conn,
    bucket: bucket,
    owner_creds: owner_creds,
    attacker_creds: attacker_creds
  } do
    upload_id = initiate_upload(conn, bucket, "big.bin", owner_creds)

    denied =
      signed_request(conn, "GET", "/#{bucket}/big.bin",
        query: "uploadId=#{upload_id}",
        creds: attacker_creds
      )

    assert denied.status == 403

    allowed =
      signed_request(conn, "GET", "/#{bucket}/big.bin",
        query: "uploadId=#{upload_id}",
        creds: owner_creds
      )

    assert allowed.status == 200
    assert allowed.resp_body =~ "<ListPartsResult"
  end

  # ---------- replay protection ----------

  test "request with stale timestamp is rejected", %{
    conn: conn,
    bucket: bucket,
    owner_creds: owner_creds
  } do
    conn =
      signed_request(conn, "GET", "/#{bucket}",
        query: "list-type=2",
        creds: owner_creds,
        amz_date: old_amz_date()
      )

    assert conn.status == 403
    assert conn.resp_body =~ "skew"
  end

  test "request with current timestamp succeeds", %{
    conn: conn,
    bucket: bucket,
    owner_creds: owner_creds
  } do
    conn = signed_request(conn, "GET", "/#{bucket}", query: "list-type=2", creds: owner_creds)
    assert conn.status == 200
  end

  # ---------- presigned URLs ----------

  test "presigned URL works, honors expiry, caps lifetime", %{
    conn: conn,
    bucket: bucket,
    owner_creds: owner_creds
  } do
    :ok = Storage.put_object(bucket, "shared.txt", "shared-data") |> elem(0)

    ok = presigned_get(conn, "/#{bucket}/shared.txt", %{}, owner_creds, expires: 3600)
    assert ok.status == 200
    assert ok.resp_body == "shared-data"

    expired =
      presigned_get(conn, "/#{bucket}/shared.txt", %{}, owner_creds,
        amz_date: old_amz_date(),
        expires: 60
      )

    assert expired.status == 403
    assert expired.resp_body =~ "expired"

    too_long =
      presigned_get(conn, "/#{bucket}/shared.txt", %{}, owner_creds, expires: 7 * 24 * 3_600 + 1)

    assert too_long.status == 403
    assert too_long.resp_body =~ "exceeds"
  end

  test "presigned URL without bucket access is denied", %{
    conn: conn,
    bucket: bucket,
    attacker_creds: attacker_creds
  } do
    :ok = Storage.put_object(bucket, "shared.txt", "shared-data") |> elem(0)

    conn = presigned_get(conn, "/#{bucket}/shared.txt", %{}, attacker_creds, expires: 3600)
    assert conn.status == 403
  end

  # ---------- key collisions & folder markers ----------

  test "file blocks subkeys with 400 instead of 500", %{
    conn: conn,
    bucket: bucket,
    owner_creds: owner_creds
  } do
    put = fn key, body ->
      signed_request(conn, "PUT", "/#{bucket}/#{key}", body: body, creds: owner_creds)
    end

    assert put.("a", "data").status == 200

    collided = put.("a/b", "data")
    assert collided.status == 400
    assert collided.resp_body =~ "collides"
  end

  test "directory blocks plain keys with 400", %{
    conn: conn,
    bucket: bucket,
    owner_creds: owner_creds
  } do
    put = fn key, body ->
      signed_request(conn, "PUT", "/#{bucket}/#{key}", body: body, creds: owner_creds)
    end

    assert put.("x/y", "data").status == 200

    collided = put.("x", "data")
    assert collided.status == 400
    assert collided.resp_body =~ "collides"
  end

  test "folder markers behave like 0-byte objects", %{
    conn: conn,
    bucket: bucket,
    owner_creds: owner_creds
  } do
    put = fn key, body ->
      signed_request(conn, "PUT", "/#{bucket}/#{key}", body: body, creds: owner_creds)
    end

    assert put.("d/", "").status == 200

    head = signed_request(conn, "HEAD", "/#{bucket}/d/", creds: owner_creds)
    assert head.status == 200

    listed =
      signed_request(conn, "GET", "/#{bucket}",
        query: "delimiter=%2F&list-type=2",
        creds: owner_creds
      )

    assert listed.status == 200
    assert listed.resp_body =~ "<Prefix>d/</Prefix>"

    deleted = signed_request(conn, "DELETE", "/#{bucket}/d/", creds: owner_creds)
    assert deleted.status == 204

    gone = signed_request(conn, "HEAD", "/#{bucket}/d/", creds: owner_creds)
    assert gone.status == 404
  end

  test "marker over a file is rejected", %{conn: conn, bucket: bucket, owner_creds: owner_creds} do
    put = fn key, body ->
      signed_request(conn, "PUT", "/#{bucket}/#{key}", body: body, creds: owner_creds)
    end

    assert put.("f", "data").status == 200

    collided = put.("f/", "")
    assert collided.status == 400
  end

  # ---------- inert object serving (stored-XSS protection) ----------

  test "object responses carry sandbox and nosniff headers", %{
    conn: conn,
    bucket: bucket,
    owner_creds: owner_creds
  } do
    :ok =
      Storage.put_object(bucket, "page.html", "<script>alert(1)</script>",
        content_type: "text/html"
      )
      |> elem(0)

    conn = signed_request(conn, "GET", "/#{bucket}/page.html", creds: owner_creds)
    assert conn.status == 200
    assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    ranged =
      signed_request(conn, "GET", "/#{bucket}/page.html",
        headers: [{"range", "bytes=0-10"}],
        creds: owner_creds
      )

    assert ranged.status == 206
    assert get_resp_header(ranged, "content-security-policy") == ["sandbox"]
  end

  test "malformed content types are rejected at upload", %{
    conn: conn,
    bucket: bucket,
    owner_creds: owner_creds
  } do
    conn =
      signed_request(conn, "PUT", "/#{bucket}/evil.txt",
        body: "x",
        headers: [{"content-type", "not a type"}],
        creds: owner_creds
      )

    assert conn.status == 400
    assert conn.resp_body =~ "Invalid content type"
    refute Storage.object_exists?(bucket, "evil.txt")
  end
end
