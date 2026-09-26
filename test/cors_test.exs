defmodule KeeplixWeb.CorsTest do
  @moduledoc """
  CORS configuration, preflight and Origin echo (item 3b).
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing

  alias Keeplix.{Accounts, Buckets, Storage}

  @cors_body """
  <CORSConfiguration>
    <CORSRule>
      <AllowedOrigin>https://app.example.com</AllowedOrigin>
      <AllowedMethod>GET</AllowedMethod>
      <AllowedMethod>PUT</AllowedMethod>
      <AllowedHeader>*</AllowedHeader>
      <MaxAgeSeconds>3000</MaxAgeSeconds>
    </CORSRule>
  </CORSConfiguration>
  """

  setup %{conn: conn} do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "cors-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "cors-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    {:ok, _, creds} = Accounts.create_access_key(owner, "cors")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    put = signed_request(conn, "PUT", "/#{bucket}/f.txt", body: "x", creds: creds)
    assert put.status == 200

    {:ok, conn: conn, bucket: bucket, creds: creds}
  end

  defp preflight(path, headers) do
    conn = Phoenix.ConnTest.build_conn()
    conn = %{conn | host: "example.com"}

    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc ->
        Plug.Conn.put_req_header(acc, k, v)
      end)

    Phoenix.ConnTest.dispatch(conn, KeeplixWeb.Endpoint, :options, path)
  end

  test "preflight denied without configuration", %{bucket: bucket} do
    conn =
      preflight("/#{bucket}/f.txt", [
        {"origin", "https://app.example.com"},
        {"access-control-request-method", "GET"}
      ])

    assert conn.status == 403
  end

  test "CORS roundtrip and preflight", %{conn: conn, bucket: bucket, creds: creds} do
    put =
      signed_request(conn, "PUT", "/#{bucket}", query: "cors=", body: @cors_body, creds: creds)

    assert put.status == 200

    get = signed_request(conn, "GET", "/#{bucket}", query: "cors=", creds: creds)
    assert get.status == 200
    assert get.resp_body =~ "https://app.example.com"
    assert get.resp_body =~ "<AllowedMethod>PUT</AllowedMethod>"

    pre =
      preflight("/#{bucket}/f.txt", [
        {"origin", "https://app.example.com"},
        {"access-control-request-method", "PUT"}
      ])

    assert pre.status == 200
    assert get_resp_header(pre, "access-control-allow-origin") == ["https://app.example.com"]
    assert get_resp_header(pre, "access-control-max-age") == ["3000"]

    foreign =
      preflight("/#{bucket}/f.txt", [
        {"origin", "https://evil.example.com"},
        {"access-control-request-method", "GET"}
      ])

    assert foreign.status == 403

    del = signed_request(conn, "DELETE", "/#{bucket}", query: "cors=", creds: creds)
    assert del.status == 200

    gone = signed_request(conn, "GET", "/#{bucket}", query: "cors=", creds: creds)
    assert gone.status == 404
  end

  test "object responses echo matching Origin", %{conn: conn, bucket: bucket, creds: creds} do
    assert signed_request(conn, "PUT", "/#{bucket}",
             query: "cors=",
             body: @cors_body,
             creds: creds
           ).status == 200

    get =
      signed_request(conn, "GET", "/#{bucket}/f.txt",
        headers: [{"origin", "https://app.example.com"}],
        creds: creds
      )

    assert get.status == 200
    assert get_resp_header(get, "access-control-allow-origin") == ["https://app.example.com"]

    plain = signed_request(conn, "GET", "/#{bucket}/f.txt", creds: creds)
    assert get_resp_header(plain, "access-control-allow-origin") == []
  end

  test "invalid CORS config rejected", %{conn: conn, bucket: bucket, creds: creds} do
    bad =
      signed_request(conn, "PUT", "/#{bucket}",
        query: "cors=",
        body: "<CORSConfiguration/>",
        creds: creds
      )

    assert bad.status == 400

    bad_method =
      signed_request(conn, "PUT", "/#{bucket}",
        query: "cors=",
        body:
          "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin><AllowedMethod>BREW</AllowedMethod></CORSRule></CORSConfiguration>",
        creds: creds
      )

    assert bad_method.status == 400
  end
end
