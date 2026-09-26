defmodule KeeplixWeb.S3RegressionTest do
  @moduledoc """
  Regression tests for real SDK flows (restic via minio-go):
  - GET ?location returns a LocationConstraint (SDKs cache it as region)
  - encoded query values verify (no double encoding)
  - empty delimiter means "no grouping"
  - Authorization header parses with and without space after commas
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing

  alias Keeplix.{Accounts, Buckets, Storage}

  @host "example.com"
  @region "us-east-1"
  @empty_sha "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  # Requests must be signed with the current time: the server rejects
  # timestamps outside a ±15 minute window (replay protection).
  defp amz_now, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
  defp date_now, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%d")

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "s3reg-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "s3reg-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, user)
    {:ok, _, creds} = Accounts.create_access_key(user, "regression")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, user: user, bucket: bucket, creds: creds}
  end

  defp signed_get(conn, path, query, creds, separator \\ ", ") do
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    amz_date = amz_now()
    date = date_now()

    canonical =
      [
        "GET",
        canonical_uri(path),
        canonical_query(query),
        "host:#{@host}\n" <>
          "x-amz-content-sha256:#{@empty_sha}\n" <>
          "x-amz-date:#{amz_date}\n",
        signed_headers,
        @empty_sha
      ]
      |> Enum.join("\n")

    scope = "#{date}/#{@region}/s3/aws4_request"
    to_sign = "AWS4-HMAC-SHA256\n#{amz_date}\n#{scope}\n#{sha256hex(canonical)}"
    key = derive_key(creds.secret, date)
    sig = hmac_hex(key, to_sign)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{creds.access_key_id}/#{scope}" <>
        separator <>
        "SignedHeaders=#{signed_headers}" <>
        separator <>
        "Signature=#{sig}"

    conn
    |> Map.put(:host, @host)
    |> put_req_header("x-amz-date", amz_date)
    |> put_req_header("x-amz-content-sha256", @empty_sha)
    |> put_req_header("authorization", auth)
    |> get(path <> "?" <> query)
  end

  test "GET ?location returns LocationConstraint", %{conn: conn, bucket: bucket, creds: creds} do
    conn = signed_get(conn, "/#{bucket}", "location=", creds)
    assert response_content_type(conn, :xml)
    assert conn.status == 200
    assert conn.resp_body =~ "<LocationConstraint"
    assert conn.resp_body =~ "us-east-1"
  end

  test "encoded query values verify (prefix with %2F)", %{
    conn: conn,
    bucket: bucket,
    creds: creds
  } do
    :ok = Storage.put_object(bucket, "data/54/abcd1234", "x") |> elem(0)
    query = "delimiter=%2F&encoding-type=url&list-type=2&prefix=data%2F"
    conn = signed_get(conn, "/#{bucket}", query, creds)
    assert conn.status == 200
    assert conn.resp_body =~ "data%2F54%2F"
    assert conn.resp_body =~ "<EncodingType>url</EncodingType>"
  end

  test "empty delimiter means no grouping", %{conn: conn, bucket: bucket, creds: creds} do
    :ok = Storage.put_object(bucket, "data/54/abcd1234", "x") |> elem(0)
    query = "delimiter=&list-type=2&prefix=data%2F"
    conn = signed_get(conn, "/#{bucket}", query, creds)
    assert conn.status == 200
    assert conn.resp_body =~ "data/54/abcd1234"
  end

  test "Authorization without spaces after commas verifies", %{
    conn: conn,
    bucket: bucket,
    creds: creds
  } do
    conn = signed_get(conn, "/#{bucket}", "location=", creds, ",")
    assert conn.status == 200
    assert conn.resp_body =~ "<LocationConstraint"
  end

  test "DeleteObjects rejects DOCTYPE markup", %{conn: conn, bucket: bucket, creds: creds} do
    body =
      ~s(<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE Delete [<!ENTITY x "evil">]><Delete><Object><Key>a</Key></Object></Delete>)

    conn = signed_request(conn, "POST", "/#{bucket}", query: "delete=", body: body, creds: creds)
    assert conn.status == 400
    assert conn.resp_body =~ "MalformedXML"
  end

  test "DeleteObjects caps body size", %{conn: conn, bucket: bucket, creds: creds} do
    big =
      "<Delete>" <>
        String.duplicate("<Object><Key>0123456789abcdef</Key></Object>", 40_000) <>
        "</Delete>"

    assert byte_size(big) > 1_000_000

    conn = signed_request(conn, "POST", "/#{bucket}", query: "delete=", body: big, creds: creds)
    assert conn.status == 400
    assert conn.resp_body =~ "EntityTooLarge"
  end

  test "valid DeleteObjects still works", %{conn: conn, bucket: bucket, creds: creds} do
    :ok = Storage.put_object(bucket, "gone.txt", "x") |> elem(0)
    body = ~s(<Delete><Object><Key>gone.txt</Key></Object></Delete>)

    conn = signed_request(conn, "POST", "/#{bucket}", query: "delete=", body: body, creds: creds)
    assert conn.status == 200
    assert conn.resp_body =~ "<Deleted>"
    refute Storage.object_exists?(bucket, "gone.txt")
  end

  test "range requests serve slices without loading the file", %{
    conn: conn,
    bucket: bucket,
    creds: creds
  } do
    data = :crypto.strong_rand_bytes(200_000)
    :ok = Storage.put_object(bucket, "big.bin", data) |> elem(0)

    conn =
      signed_request(conn, "GET", "/#{bucket}/big.bin",
        headers: [{"range", "bytes=10-99"}],
        creds: creds
      )

    assert conn.status == 206
    assert conn.resp_body == binary_part(data, 10, 90)
    assert get_resp_header(conn, "content-range") == ["bytes 10-99/200000"]

    # Multi-chunk span (> 64 KiB chunks).
    conn =
      signed_request(conn, "GET", "/#{bucket}/big.bin",
        headers: [{"range", "bytes=0-150000"}],
        creds: creds
      )

    assert conn.status == 206
    assert conn.resp_body == binary_part(data, 0, 150_001)

    # Open end.
    conn =
      signed_request(conn, "GET", "/#{bucket}/big.bin",
        headers: [{"range", "bytes=199990-"}],
        creds: creds
      )

    assert conn.status == 206
    assert conn.resp_body == binary_part(data, 199_990, 10)

    # Out of bounds.
    conn =
      signed_request(conn, "GET", "/#{bucket}/big.bin",
        headers: [{"range", "bytes=999999-9999999"}],
        creds: creds
      )

    assert conn.status == 416
  end
end
