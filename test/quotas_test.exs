defmodule KeeplixWeb.QuotasTest do
  @moduledoc """
  Storage limits (P2): global max object size, per-bucket quotas on all
  write paths, and quota management in the admin UI.
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing
  import Phoenix.LiveViewTest

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "quota-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "quota-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    {:ok, _, creds} = Accounts.create_access_key(owner, "quota")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, conn: conn, owner: owner, bucket: bucket, creds: creds}
  end

  defp set_quota(bucket, bytes) do
    bucket |> Buckets.get_bucket() |> Buckets.update_bucket(%{quota_bytes: bytes})
  end

  test "usage ledger tracks puts, overwrites and deletes", %{
    conn: conn,
    bucket: bucket,
    creds: creds
  } do
    put = fn key, body ->
      signed_request(conn, "PUT", "/#{bucket}/#{key}", body: body, creds: creds)
    end

    assert %{status: 200} = put.("a.txt", "12345")
    assert %{bytes: 5, count: 1} = Buckets.usage(Buckets.get_bucket(bucket))

    assert %{status: 200} = put.("a.txt", "1234567890")
    assert %{bytes: 10, count: 1} = Buckets.usage(Buckets.get_bucket(bucket))

    assert %{status: 200} = put.("b.txt", "123")
    assert %{bytes: 13, count: 2} = Buckets.usage(Buckets.get_bucket(bucket))

    assert %{status: 204} = signed_request(conn, "DELETE", "/#{bucket}/b.txt", creds: creds)
    # Trash still occupies disk, so quota keeps counting it until purged.
    assert %{bytes: 13, count: 2} = Buckets.usage(Buckets.get_bucket(bucket))

    assert :ok = Storage.purge_object(bucket, "b.txt")
    assert %{bytes: 10, count: 1} = Buckets.usage(Buckets.get_bucket(bucket))
  end

  test "multipart complete updates the ledger", %{conn: conn, bucket: bucket, creds: creds} do
    init = signed_request(conn, "POST", "/#{bucket}/m.bin", query: "uploads=", creds: creds)
    assert init.status == 200
    [_, upload_id] = Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, init.resp_body)

    part =
      signed_request(conn, "PUT", "/#{bucket}/m.bin",
        query: "partNumber=1&uploadId=#{upload_id}",
        body: "123456",
        creds: creds
      )

    assert part.status == 200

    body =
      ~s(<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>"x"</ETag></Part></CompleteMultipartUpload>)

    done =
      signed_request(conn, "POST", "/#{bucket}/m.bin",
        query: "uploadId=#{upload_id}",
        body: body,
        creds: creds
      )

    assert done.status == 200
    assert %{bytes: 6, count: 1} = Buckets.usage(Buckets.get_bucket(bucket))
  end

  test "bucket_usage sums stored bytes", %{bucket: bucket} do
    assert Storage.bucket_usage(bucket) == 0
    :ok = Storage.put_object(bucket, "a.txt", "12345") |> elem(0)
    :ok = Storage.put_object(bucket, "sub/b.txt", "1234567") |> elem(0)
    assert Storage.bucket_usage(bucket) == 12
  end

  test "quota_allows? is open without quota", %{bucket: bucket} do
    b = Buckets.get_bucket(bucket)
    assert :ok = Buckets.quota_allows?(b, 1_000_000_000)
  end

  test "S3 PUT over quota is rejected", %{conn: conn, bucket: bucket, creds: creds} do
    {:ok, _} = set_quota(bucket, 10)

    conn =
      signed_request(conn, "PUT", "/#{bucket}/big.txt",
        body: String.duplicate("x", 20),
        creds: creds
      )

    assert conn.status == 400
    assert conn.resp_body =~ "quota"
    refute Storage.object_exists?(bucket, "big.txt")
  end

  test "S3 PUT within quota succeeds", %{conn: conn, bucket: bucket, creds: creds} do
    {:ok, _} = set_quota(bucket, 1_000)

    conn = signed_request(conn, "PUT", "/#{bucket}/small.txt", body: "tiny", creds: creds)

    assert conn.status == 200
    assert Storage.object_exists?(bucket, "small.txt")
  end

  test "global max object size is enforced", %{conn: conn, bucket: bucket, creds: creds} do
    old = Application.get_env(:keeplix, :max_object_bytes)
    Application.put_env(:keeplix, :max_object_bytes, 10)

    on_exit(fn ->
      if old,
        do: Application.put_env(:keeplix, :max_object_bytes, old),
        else: Application.delete_env(:keeplix, :max_object_bytes)
    end)

    conn =
      signed_request(conn, "PUT", "/#{bucket}/big.txt",
        body: String.duplicate("x", 11),
        creds: creds
      )

    assert conn.status == 400
    assert conn.resp_body =~ "maximum size"
    refute Storage.object_exists?(bucket, "big.txt")
  end

  test "multipart complete over quota is rejected", %{conn: conn, bucket: bucket, creds: creds} do
    {:ok, _} = set_quota(bucket, 10)

    init =
      signed_request(conn, "POST", "/#{bucket}/big.bin", query: "uploads=", creds: creds)

    assert init.status == 200
    [_, upload_id] = Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, init.resp_body)

    for n <- [1, 2] do
      part =
        signed_request(conn, "PUT", "/#{bucket}/big.bin",
          query: "partNumber=#{n}&uploadId=#{upload_id}",
          body: "123456",
          creds: creds
        )

      assert part.status == 200
    end

    body =
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"x\"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>\"y\"</ETag></Part></CompleteMultipartUpload>"

    done =
      signed_request(conn, "POST", "/#{bucket}/big.bin",
        query: "uploadId=#{upload_id}",
        body: body,
        creds: creds
      )

    assert done.status == 400
    assert done.resp_body =~ "quota"
    refute Storage.object_exists?(bucket, "big.bin")
  end

  test "admin can set quota via UI", %{conn: conn} do
    {:ok, admin} =
      Accounts.create_user(%{
        username: "quota-admin-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "admin"
      })

    bucket = "quota-ui-#{System.unique_integer([:positive])}"
    {:ok, b} = Buckets.create_bucket(bucket, admin)
    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, view, _} =
      conn |> Plug.Test.init_test_session(%{user_id: admin.id}) |> live("/admin/buckets")

    render_click(view, "select", %{"id" => b.id})

    html = render_submit(view, "save-quota", %{"quota_mb" => "1"})
    assert html =~ "Quota updated"
    assert Buckets.get_bucket(bucket).quota_bytes == 1_048_576

    html = render_submit(view, "save-quota", %{"quota_mb" => "abc"})
    assert html =~ "Invalid quota"

    html = render_submit(view, "save-quota", %{"quota_mb" => ""})
    assert html =~ "Quota updated"
    assert Buckets.get_bucket(bucket).quota_bytes == nil
  end

  test "browser upload over quota is rejected", %{conn: conn, owner: owner, bucket: bucket} do
    {:ok, _} = set_quota(bucket, 5)

    {:ok, view, _} =
      conn |> Plug.Test.init_test_session(%{user_id: owner.id}) |> live("/app/b/#{bucket}")

    file =
      file_input(view, "#upload-form", :files, [
        %{name: "big.txt", content: "0123456789", size: 10, type: "text/plain"}
      ])

    render_upload(file, "big.txt")
    html = view |> form("#upload-form") |> render_submit()

    assert html =~ "quota exceeded"
    refute Storage.object_exists?(bucket, "big.txt")
  end
end
