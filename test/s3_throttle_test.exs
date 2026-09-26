defmodule KeeplixWeb.S3ThrottleTest do
  @moduledoc """
  S3 API brute-force protection (P1): repeated authentication failures
  from one IP lead to 429 SlowDown.
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing

  alias Keeplix.{Accounts, Buckets, RateLimit, Storage}

  @tiny [max_attempts: 3, window_ms: 60_000, block_ms: 60_000]

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "throttle-s3-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "throttle-s3-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, user)
    {:ok, _, creds} = Accounts.create_access_key(user, "throttle")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    old = Application.get_env(:keeplix, RateLimit, [])
    Application.put_env(:keeplix, RateLimit, s3_ip: @tiny)
    RateLimit.reset_all()

    on_exit(fn ->
      Application.put_env(:keeplix, RateLimit, old)
      RateLimit.reset_all()
    end)

    {:ok, conn: conn, bucket: bucket, creds: creds}
  end

  test "repeated S3 auth failures lead to 429", %{conn: conn, bucket: bucket, creds: creds} do
    wrong = %{creds | secret: "wrong-secret"}

    conn = signed_request(conn, "GET", "/#{bucket}", query: "list-type=2", creds: wrong)
    assert conn.status == 403

    conn = signed_request(conn, "GET", "/#{bucket}", query: "list-type=2", creds: wrong)
    assert conn.status == 403

    conn = signed_request(conn, "GET", "/#{bucket}", query: "list-type=2", creds: wrong)
    assert conn.status == 403

    conn = signed_request(conn, "GET", "/#{bucket}", query: "list-type=2", creds: wrong)
    assert conn.status == 429
    assert conn.resp_body =~ "SlowDown"
  end

  test "successes do not reset S3 failure counters", %{conn: conn, bucket: bucket, creds: creds} do
    wrong = %{creds | secret: "wrong-secret"}

    signed_request(conn, "GET", "/#{bucket}", query: "list-type=2", creds: wrong)
    signed_request(conn, "GET", "/#{bucket}", query: "list-type=2", creds: wrong)

    ok = signed_request(conn, "GET", "/#{bucket}", query: "list-type=2", creds: creds)
    assert ok.status == 200

    # Counter survived the success: the next failure trips the block.
    conn = signed_request(conn, "GET", "/#{bucket}", query: "list-type=2", creds: wrong)
    assert conn.status == 403

    conn = signed_request(conn, "GET", "/#{bucket}", query: "list-type=2", creds: wrong)
    assert conn.status == 429
    assert conn.resp_body =~ "SlowDown"
  end
end
