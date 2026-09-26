defmodule KeeplixWeb.ConditionalRequestsTest do
  @moduledoc """
  Conditional Requests + Response-Overrides (B1) und NotImplemented-Stubs (B2).
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "cond-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "cond-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    {:ok, _, creds} = Accounts.create_access_key(owner, "cond")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    put =
      signed_request(conn, "PUT", "/#{bucket}/f.txt",
        body: "hello",
        headers: [{"content-type", "application/octet-stream"}],
        creds: creds
      )

    assert put.status == 200
    [etag] = get_resp_header(put, "etag")

    get = signed_request(conn, "GET", "/#{bucket}/f.txt", creds: creds)
    assert get.status == 200
    [last_modified] = get_resp_header(get, "last-modified")

    {:ok, conn: conn, bucket: bucket, creds: creds, etag: etag, last_modified: last_modified}
  end

  test "If-None-Match mit passendem ETag -> 304", %{
    conn: conn,
    bucket: bucket,
    creds: creds,
    etag: etag
  } do
    conn =
      signed_request(conn, "GET", "/#{bucket}/f.txt",
        headers: [{"if-none-match", etag}],
        creds: creds
      )

    assert conn.status == 304
    assert conn.resp_body == ""
  end

  test "If-None-Match: * und Weak-ETag -> 304", %{
    conn: conn,
    bucket: bucket,
    creds: creds,
    etag: etag
  } do
    bare = etag |> String.trim("\"")

    star =
      signed_request(conn, "GET", "/#{bucket}/f.txt",
        headers: [{"if-none-match", "*"}],
        creds: creds
      )

    assert star.status == 304

    weak =
      signed_request(conn, "GET", "/#{bucket}/f.txt",
        headers: [{"if-none-match", "W/\"#{bare}\""}],
        creds: creds
      )

    assert weak.status == 304
  end

  test "If-None-Match mismatch -> 200", %{conn: conn, bucket: bucket, creds: creds} do
    conn =
      signed_request(conn, "GET", "/#{bucket}/f.txt",
        headers: [{"if-none-match", "\"deadbeef\""}],
        creds: creds
      )

    assert conn.status == 200
    assert conn.resp_body == "hello"
  end

  test "If-Modified-Since steuert 304/200", %{
    conn: conn,
    bucket: bucket,
    creds: creds,
    last_modified: last_modified
  } do
    same =
      signed_request(conn, "GET", "/#{bucket}/f.txt",
        headers: [{"if-modified-since", last_modified}],
        creds: creds
      )

    assert same.status == 304

    old =
      signed_request(conn, "GET", "/#{bucket}/f.txt",
        headers: [{"if-modified-since", "Thu, 01 Jan 1970 00:00:01 GMT"}],
        creds: creds
      )

    assert old.status == 200
  end

  test "If-Match mismatch -> 412, Treffer -> 200", %{
    conn: conn,
    bucket: bucket,
    creds: creds,
    etag: etag
  } do
    bad =
      signed_request(conn, "GET", "/#{bucket}/f.txt",
        headers: [{"if-match", "\"deadbeef\""}],
        creds: creds
      )

    assert bad.status == 412
    assert bad.resp_body =~ "PreconditionFailed"

    good =
      signed_request(conn, "GET", "/#{bucket}/f.txt", headers: [{"if-match", etag}], creds: creds)

    assert good.status == 200
  end

  test "HEAD mit If-None-Match -> 304", %{conn: conn, bucket: bucket, creds: creds, etag: etag} do
    conn =
      signed_request(conn, "HEAD", "/#{bucket}/f.txt",
        headers: [{"if-none-match", etag}],
        creds: creds
      )

    assert conn.status == 304
  end

  test "Response-Overrides aendern Header, nicht Body", %{
    conn: conn,
    bucket: bucket,
    creds: creds
  } do
    conn =
      signed_request(conn, "GET", "/#{bucket}/f.txt",
        query: "response-content-type=text%2Fplain&response-content-disposition=attachment",
        creds: creds
      )

    assert conn.status == 200
    assert conn.resp_body == "hello"
    assert [ct] = get_resp_header(conn, "content-type")
    assert String.starts_with?(ct, "text/plain")
    assert get_resp_header(conn, "content-disposition") == ["attachment"]
  end

  test "Response-Override mit CRLF -> 400", %{conn: conn, bucket: bucket, creds: creds} do
    conn =
      signed_request(conn, "GET", "/#{bucket}/f.txt",
        query: "response-content-type=text%2Fplain%0D%0AX-Injected%3A+1",
        creds: creds
      )

    assert conn.status == 400
  end

  test "Presigned GET mit Response-Override", %{conn: conn, bucket: bucket, creds: creds} do
    conn =
      presigned_get(
        conn,
        "/#{bucket}/f.txt",
        %{"response-content-type" => "text/plain"},
        creds,
        []
      )

    assert conn.status == 200
    assert [ct] = get_resp_header(conn, "content-type")
    assert String.starts_with?(ct, "text/plain")
  end

  test "?tagging und ?acl am Objekt sind implementiert (kein 501)", %{
    conn: conn,
    bucket: bucket,
    creds: creds
  } do
    tagging = signed_request(conn, "GET", "/#{bucket}/f.txt", query: "tagging=", creds: creds)
    assert tagging.status == 200
    assert tagging.resp_body =~ "Tagging"

    acl = signed_request(conn, "GET", "/#{bucket}/f.txt", query: "acl=", creds: creds)
    assert acl.status == 200
    assert acl.resp_body =~ "AccessControlPolicy"
  end

  test "?acl und ?cors am Bucket sind implementiert (kein 501)", %{
    conn: conn,
    bucket: bucket,
    creds: creds
  } do
    acl = signed_request(conn, "GET", "/#{bucket}", query: "acl=", creds: creds)
    assert acl.status == 200

    cors = signed_request(conn, "GET", "/#{bucket}", query: "cors=", creds: creds)
    # Keine Config -> 404 statt leerer Antwort.
    assert cors.status == 404
  end

  test "unsignierte ?tagging-Anfrage -> 403", %{conn: conn, bucket: bucket} do
    conn = Phoenix.ConnTest.dispatch(conn, KeeplixWeb.Endpoint, :get, "/#{bucket}/f.txt?tagging=")
    assert conn.status == 403
  end

  test "OPTIONS Preflight -> 403 ohne HTML", %{conn: conn, bucket: bucket} do
    conn = Phoenix.ConnTest.dispatch(conn, KeeplixWeb.Endpoint, :options, "/#{bucket}/f.txt")
    assert conn.status == 403
    assert conn.resp_body =~ "AccessDenied"
  end
end
