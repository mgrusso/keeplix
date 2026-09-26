defmodule KeeplixWeb.FileDownloadTest do
  @moduledoc """
  UI downloads authorize like the S3 API and never reflect raw keys
  into response headers (P1).
  """
  use KeeplixWeb.ConnCase

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "dl-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    stranger = create_user("dl-stranger")
    bucket = "dl-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    :ok = Storage.put_object(bucket, "we\"ird.txt", "x") |> elem(0)

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, conn: conn, owner: owner, stranger: stranger, bucket: bucket}
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

  test "filename is sanitized in Content-Disposition", %{conn: conn, owner: owner, bucket: bucket} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: owner.id})
      |> get("/files/#{bucket}/we%22ird.txt")

    assert conn.status == 200
    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(filename="we_ird.txt")
    refute disposition =~ ~s(filename="we"ird)
  end

  test "without read access there is no download (and no distinction)", %{
    conn: conn,
    stranger: stranger,
    bucket: bucket
  } do
    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: stranger.id})
      |> get("/files/#{bucket}/we%22ird.txt")

    assert conn.status == 404
  end
end
