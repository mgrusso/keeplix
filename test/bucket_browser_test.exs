defmodule KeeplixWeb.BucketBrowserTest do
  use KeeplixWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "browser-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "browser-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, user)
    :ok = Storage.put_object(bucket, "a.txt", "a") |> elem(0)
    :ok = Storage.put_object(bucket, "dir/b.txt", "b") |> elem(0)
    :ok = Storage.put_object(bucket, "dir/sub/c.txt", "c") |> elem(0)

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, bucket: bucket}
  end

  test "folder click navigates into prefix", %{conn: conn, bucket: bucket} do
    {:ok, view, html} = live(conn, "/app/b/#{bucket}")
    assert html =~ "a.txt"

    html =
      view
      |> element("#prefixes button[phx-click='navigate']")
      |> render_click()

    assert html =~ "dir/"
    assert html =~ "b.txt"
    refute html =~ "a.txt"
  end

  test "bucket crumb resets prefix", %{conn: conn, bucket: bucket} do
    {:ok, view, _} = live(conn, "/app/b/#{bucket}?prefix=dir%2F")
    assert render(view) =~ "b.txt"

    html = view |> element("nav a", bucket) |> render_click()
    assert html =~ "a.txt"
  end

  test "ancestor crumb jumps to parent folder", %{conn: conn, bucket: bucket} do
    {:ok, view, _} = live(conn, "/app/b/#{bucket}?prefix=dir%2Fsub%2F")
    assert render(view) =~ "c.txt"

    html = view |> element("nav a", "dir") |> render_click()
    assert html =~ "b.txt"
    refute html =~ "a.txt"
  end
end
