defmodule KeeplixWeb.PageControllerTest do
  use KeeplixWeb.ConnCase

  test "GET / redirects browsers to /app", %{conn: conn} do
    conn = get(conn, "/")
    assert redirected_to(conn) == "/app"
  end

  test "GET / with S3 auth requires a signature", %{conn: conn} do
    conn =
      conn
      |> put_req_header(
        "authorization",
        "AWS4-HMAC-SHA256 Credential=X/20240101/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=00"
      )
      |> get("/?list-type=2")

    assert response_content_type(conn, :xml)
    assert conn.status in [403, 400]
  end
end
