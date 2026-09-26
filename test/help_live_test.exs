defmodule KeeplixWeb.HelpLiveTest do
  @moduledoc """
  Help page, copy buttons and search shortcut hook (B6).
  """
  use KeeplixWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "help-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "help-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, user)
    {:ok, _, _} = Accounts.create_access_key(user, "help-share")
    :ok = Storage.put_object(bucket, "doc.txt", "hi") |> elem(0)

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, bucket: bucket}
  end

  test "help page renders with shortcuts", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/app/help")
    assert html =~ "Connect an S3 client"
    assert html =~ "Keyboard shortcuts"
    assert html =~ "search"
  end

  test "help requires login" do
    {:error, {:redirect, _}} = live(build_conn(), "/app/help")
  end

  test "share dialog has a copy button", %{conn: conn, bucket: bucket} do
    {:ok, view, _} = live(conn, "/app/b/#{bucket}")
    html = view |> element("button[phx-click='share']") |> render_click()
    assert html =~ "Share link"
    assert has_element?(view, "#share-copy")
  end

  test "search form carries the shortcut hook", %{conn: conn, bucket: bucket} do
    {:ok, _view, html} = live(conn, "/app/b/#{bucket}")
    assert html =~ "search-input"
    assert html =~ "BrowserKeys"
  end

  test "new access key shows copy buttons", %{conn: conn} do
    {:ok, view, _} = live(conn, "/app/keys")

    html =
      view
      |> form("form[phx-submit='create']", %{description: "test-key"})
      |> render_submit()

    assert html =~ "Copy now"
    assert html =~ "copy-access-key"
    assert html =~ "copy-secret"
  end
end
