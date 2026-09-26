defmodule KeeplixWeb.MultipartListingTest do
  @moduledoc """
  Real ListMultipartUploads (B5): S3 API, storage listing, browser UI.
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing
  import Phoenix.LiveViewTest

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "mp-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "mp-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, user)
    {:ok, _, creds} = Accounts.create_access_key(user, "mp")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, conn: conn, user: user, bucket: bucket, creds: creds}
  end

  test "list_multipart_uploads is bucket-scoped", %{bucket: bucket} do
    {:ok, id} = Storage.create_multipart(bucket, "big.bin")
    {:ok, _} = Storage.create_multipart("other-bucket-never-exists", "x.bin")

    assert [%{upload_id: ^id, key: "big.bin"}] = Storage.list_multipart_uploads(bucket)
    assert [] = Storage.list_multipart_uploads(bucket <> "-empty-never")

    Storage.abort_multipart(id)
  end

  test "S3 GET ?uploads lists in-flight uploads", %{conn: conn, bucket: bucket, creds: creds} do
    empty = signed_request(conn, "GET", "/#{bucket}", query: "uploads=", creds: creds)
    assert empty.status == 200
    assert empty.resp_body =~ "ListMultipartUploadsResult"
    refute empty.resp_body =~ "<Upload>"

    init = signed_request(conn, "POST", "/#{bucket}/big.bin", query: "uploads=", creds: creds)
    assert init.status == 200
    [_, upload_id] = Regex.run(~r/<UploadId>([0-9a-f]{32})<\/UploadId>/, init.resp_body)

    listed = signed_request(conn, "GET", "/#{bucket}", query: "uploads=", creds: creds)
    assert listed.status == 200
    assert listed.resp_body =~ "<Key>big.bin</Key>"
    assert listed.resp_body =~ upload_id

    Storage.abort_multipart(upload_id)

    gone = signed_request(conn, "GET", "/#{bucket}", query: "uploads=", creds: creds)
    refute gone.resp_body =~ "<Upload>"
  end

  test "browser shows uploads and abort removes them", %{conn: conn, user: user, bucket: bucket} do
    {:ok, _} = Storage.create_multipart(bucket, "big.bin")

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, "/app/b/#{bucket}")

    assert has_element?(view, "#multipart-uploads")
    assert render(view) =~ "big.bin"

    html = view |> element("#multipart-uploads button", "Abort") |> render_click()
    refute html =~ "big.bin"
    assert [] = Storage.list_multipart_uploads(bucket)
  end
end
