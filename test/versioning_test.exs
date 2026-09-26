defmodule KeeplixWeb.VersioningTest do
  @moduledoc """
  S3 object versioning end to end (Phase C).
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing
  import Phoenix.LiveViewTest

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "ver-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "ver-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    {:ok, _, creds} = Accounts.create_access_key(owner, "versioning")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, conn: conn, owner: owner, bucket: bucket, creds: creds}
  end

  defp set_versioning(conn, bucket, creds, status) do
    body = ~s(<VersioningConfiguration><Status>#{status}</Status></VersioningConfiguration>)
    signed_request(conn, "PUT", "/#{bucket}", query: "versioning=", body: body, creds: creds)
  end

  defp put(conn, bucket, key, body, creds) do
    signed_request(conn, "PUT", "/#{bucket}/#{key}", body: body, creds: creds)
  end

  defp vid(conn) do
    case get_resp_header(conn, "x-amz-version-id") do
      [id] -> id
      [] -> nil
    end
  end

  test "versioning state machine via S3", %{conn: conn, bucket: bucket, creds: creds} do
    get = signed_request(conn, "GET", "/#{bucket}", query: "versioning=", creds: creds)
    assert get.status == 200
    refute get.resp_body =~ "<Status>"

    assert set_versioning(conn, bucket, creds, "Enabled").status == 200

    get = signed_request(conn, "GET", "/#{bucket}", query: "versioning=", creds: creds)
    assert get.resp_body =~ "<Status>Enabled</Status>"

    assert set_versioning(conn, bucket, creds, "Suspended").status == 200
    # Illegal: back to off.
    bad = set_versioning(conn, bucket, creds, "Off")
    assert bad.status == 400
  end

  test "non-admins cannot change versioning", %{conn: conn, bucket: bucket} do
    {:ok, stranger} =
      Accounts.create_user(%{
        username: "ver-s-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    {:ok, _, stranger_creds} = Accounts.create_access_key(stranger, "x")
    b = Buckets.get_bucket(bucket)
    {:ok, _} = Buckets.grant_permission(b.id, "write", user_id: stranger.id, group_id: nil)

    conn = set_versioning(conn, bucket, stranger_creds, "Enabled")
    assert conn.status == 403
  end

  test "puts create versions, latest wins", %{conn: conn, bucket: bucket, creds: creds} do
    assert set_versioning(conn, bucket, creds, "Enabled").status == 200

    v1 = conn |> put(bucket, "f.txt", "one", creds) |> vid()
    v2 = conn |> put(bucket, "f.txt", "two", creds) |> vid()
    assert is_binary(v1) and is_binary(v2) and v1 != v2

    get = signed_request(conn, "GET", "/#{bucket}/f.txt", creds: creds)
    assert get.status == 200
    assert get.resp_body == "two"
    assert vid(get) == v2

    old = signed_request(conn, "GET", "/#{bucket}/f.txt", query: "versionId=#{v1}", creds: creds)
    assert old.status == 200
    assert old.resp_body == "one"

    head =
      signed_request(conn, "HEAD", "/#{bucket}/f.txt", query: "versionId=#{v1}", creds: creds)

    assert head.status == 200
    assert vid(head) == v1
  end

  test "delete markers hide, version delete restores", %{conn: conn, bucket: bucket, creds: creds} do
    assert set_versioning(conn, bucket, creds, "Enabled").status == 200
    assert put(conn, bucket, "f.txt", "data", creds).status == 200

    del = signed_request(conn, "DELETE", "/#{bucket}/f.txt", creds: creds)
    assert del.status == 204
    assert get_resp_header(del, "x-amz-delete-marker") == ["true"]
    marker_id = vid(del)
    assert is_binary(marker_id)

    gone = signed_request(conn, "GET", "/#{bucket}/f.txt", creds: creds)
    assert gone.status == 404
    assert get_resp_header(gone, "x-amz-delete-marker") == ["true"]

    versions = signed_request(conn, "GET", "/#{bucket}", query: "versions=", creds: creds)
    assert versions.status == 200
    assert versions.resp_body =~ "<DeleteMarker>"
    assert versions.resp_body =~ marker_id

    undelete =
      signed_request(conn, "DELETE", "/#{bucket}/f.txt",
        query: "versionId=#{marker_id}",
        creds: creds
      )

    assert undelete.status == 204

    back = signed_request(conn, "GET", "/#{bucket}/f.txt", creds: creds)
    assert back.status == 200
    assert back.resp_body == "data"
  end

  test "unknown versions 404", %{conn: conn, bucket: bucket, creds: creds} do
    assert put(conn, bucket, "f.txt", "data", creds).status == 200

    missing =
      signed_request(conn, "GET", "/#{bucket}/f.txt",
        query: "versionId=#{String.duplicate("0", 32)}",
        creds: creds
      )

    assert missing.status == 404

    del =
      signed_request(conn, "DELETE", "/#{bucket}/f.txt",
        query: "versionId=#{String.duplicate("0", 32)}",
        creds: creds
      )

    assert del.status == 404
    assert del.resp_body =~ "NoSuchVersion"
  end

  test "suspended overwrites null, keeps history", %{conn: conn, bucket: bucket, creds: creds} do
    assert set_versioning(conn, bucket, creds, "Enabled").status == 200
    v1 = conn |> put(bucket, "f.txt", "one", creds) |> vid()
    assert set_versioning(conn, bucket, creds, "Suspended").status == 200

    assert put(conn, bucket, "f.txt", "two", creds).status == 200

    current = signed_request(conn, "GET", "/#{bucket}/f.txt", creds: creds)
    assert current.resp_body == "two"

    old = signed_request(conn, "GET", "/#{bucket}/f.txt", query: "versionId=#{v1}", creds: creds)
    assert old.status == 200
    assert old.resp_body == "one"
  end

  test "quota counts every version", %{conn: conn, bucket: bucket, creds: creds} do
    b = Buckets.get_bucket(bucket)
    {:ok, _} = Buckets.update_bucket(b, %{quota_bytes: 10})

    assert set_versioning(conn, bucket, creds, "Enabled").status == 200
    assert put(conn, bucket, "f.txt", "123456", creds).status == 200

    denied = put(conn, bucket, "f.txt", "123456", creds)
    assert denied.status == 400
    assert denied.resp_body =~ "quota"
  end

  test "admin UI toggles versioning", %{owner: owner} do
    {:ok, admin} =
      Accounts.create_user(%{
        username: "ver-a-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "admin"
      })

    bucket = "ver-ui-#{System.unique_integer([:positive])}"
    {:ok, b} = Buckets.create_bucket(bucket, admin)
    on_exit(fn -> Storage.delete_bucket(bucket) end)
    _ = owner

    {:ok, view, _} =
      build_conn() |> Plug.Test.init_test_session(%{user_id: admin.id}) |> live("/admin/buckets")

    render_click(view, "select", %{"id" => b.id})
    html = render_submit(view, "save-versioning", %{"versioning" => "enabled"})
    assert html =~ "Versioning updated"
    assert Buckets.get_bucket(bucket).versioning == "enabled"

    html = render_submit(view, "save-versioning", %{"versioning" => "off"})
    assert html =~ "Invalid versioning transition"
  end
end
