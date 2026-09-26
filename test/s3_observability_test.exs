defmodule KeeplixWeb.S3ObservabilityTest do
  @moduledoc """
  S3 observability (B4): telemetry event per request, access-log line.
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "obs-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "obs-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    {:ok, _, creds} = Accounts.create_access_key(owner, "obs")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    handler = "obs-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:keeplix, :s3, :request],
      fn _event, meas, meta, _ ->
        send(self(), {:s3_event, meas, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, conn: conn, bucket: bucket, creds: creds}
  end

  test "GET emits telemetry with method/status", %{conn: conn, bucket: bucket, creds: creds} do
    conn = signed_request(conn, "GET", "/#{bucket}", creds: creds)
    assert conn.status == 200

    assert_received {:s3_event, %{duration: duration}, meta}
    assert is_integer(duration) and duration >= 0
    assert meta.method == "GET"
    assert meta.status == 200
    assert meta.bucket == bucket
  end

  test "failed auth still emits telemetry", %{conn: conn, bucket: bucket} do
    conn = Phoenix.ConnTest.dispatch(conn, KeeplixWeb.Endpoint, :get, "/#{bucket}")
    assert conn.status in [400, 403]

    assert_received {:s3_event, _, %{method: "GET", status: status}}
    assert status in [400, 403]
  end

  test "access log line is appended when configured", %{conn: conn, bucket: bucket, creds: creds} do
    path = Path.join(System.tmp_dir!(), "s3-access-#{System.unique_integer([:positive])}.log")
    Application.put_env(:keeplix, :s3_access_log, path)

    on_exit(fn ->
      Application.delete_env(:keeplix, :s3_access_log)
      File.rm(path)
    end)

    conn = signed_request(conn, "GET", "/#{bucket}", creds: creds)
    assert conn.status == 200

    line = File.read!(path)
    assert line =~ "GET"
    assert line =~ "/#{bucket}"
    assert line =~ " 200 "
  end
end
