defmodule KeeplixWeb.LiveViewAuthzTest do
  @moduledoc """
  Server-side authorization tests for LiveView events (P0):

  - bucket browser delete/upload require write permission
    (hiding buttons in the template is not sufficient)
  - access-key deletion is scoped to the key owner's own keys
  """
  use KeeplixWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    owner = create_user("lv-owner")
    reader = create_user("lv-reader")
    bucket = "lv-authz-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    :ok = Storage.put_object(bucket, "doc.txt", "content") |> elem(0)

    b = Buckets.get_bucket(bucket)
    {:ok, _} = Buckets.grant_permission(b.id, "read", user_id: reader.id, group_id: nil)

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, conn: conn, owner: owner, reader: reader, bucket: bucket}
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

  defp login(conn, user) do
    Plug.Test.init_test_session(conn, %{user_id: user.id})
  end

  test "read-only user cannot delete objects via event", %{
    conn: conn,
    reader: reader,
    bucket: bucket
  } do
    {:ok, view, _} = conn |> login(reader) |> live("/app/b/#{bucket}")

    html = render_click(view, :delete, %{"key" => "doc.txt"})
    assert html =~ "Not authorized"
    assert Storage.object_exists?(bucket, "doc.txt")
  end

  test "read-only user cannot upload via event", %{conn: conn, reader: reader, bucket: bucket} do
    {:ok, view, _} = conn |> login(reader) |> live("/app/b/#{bucket}")

    html = render_submit(view, :upload, %{})
    assert html =~ "Not authorized"
  end

  test "writer can delete objects via event", %{conn: conn, owner: owner, bucket: bucket} do
    {:ok, view, _} = conn |> login(owner) |> live("/app/b/#{bucket}")

    html = render_click(view, :delete, %{"key" => "doc.txt"})
    assert html =~ "Deleted"
    refute Storage.object_exists?(bucket, "doc.txt")
  end

  test "unknown bucket redirects to the app instead of crashing", %{conn: conn, owner: owner} do
    assert {:error, {:live_redirect, %{to: "/app"}}} =
             live(conn |> login(owner), "/app/b/no-such-bucket-xyz")
  end

  test "bucket without any grant redirects to the app", %{conn: conn, bucket: bucket} do
    stranger = create_user("lv-stranger")

    assert {:error, {:live_redirect, %{to: "/app"}}} =
             live(conn |> login(stranger), "/app/b/#{bucket}")
  end

  test "user cannot delete another user's access key", %{conn: conn} do
    alice = create_user("lv-alice")
    bob = create_user("lv-bob")
    {:ok, record, _} = Accounts.create_access_key(alice, "alice-key")

    {:ok, view, _} = conn |> login(bob) |> live("/app/keys")

    html = render_click(view, :delete, %{"id" => record.id})
    assert html =~ "Not authorized"
    assert %Accounts.AccessKey{} = Accounts.get_access_key(record.id)
  end

  test "user can delete their own access key", %{conn: conn} do
    bob = create_user("lv-bobself")
    {:ok, record, _} = Accounts.create_access_key(bob, "bob-key")

    {:ok, view, _} = conn |> login(bob) |> live("/app/keys")

    html = render_click(view, :delete, %{"id" => record.id})
    assert html =~ "Key deleted"
    assert Accounts.get_access_key(record.id) == nil
  end

  test "user can rotate their own access key", %{conn: conn} do
    bob = create_user("lv-bobrotate")
    {:ok, old, _} = Accounts.create_access_key(bob, "bob-key")

    {:ok, view, _} = conn |> login(bob) |> live("/app/keys")

    html = render_click(view, :rotate, %{"id" => old.id})
    assert html =~ "Key rotated"
    assert html =~ "will not be shown again"
    assert Accounts.get_access_key(old.id) == nil
  end

  test "user cannot rotate another user's access key", %{conn: conn} do
    alice = create_user("lv-alicerot")
    bob = create_user("lv-bobrot")
    {:ok, old, _} = Accounts.create_access_key(alice, "alice-key")

    {:ok, view, _} = conn |> login(bob) |> live("/app/keys")

    html = render_click(view, :rotate, %{"id" => old.id})
    assert html =~ "Not authorized"
    assert %Accounts.AccessKey{} = Accounts.get_access_key(old.id)
  end

  test "logout is DELETE-only" do
    user = create_user("lv-logout")

    gone =
      build_conn()
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> delete("/logout")

    assert redirected_to(gone) == "/login"
    assert get_session(gone, :user_id) == nil

    stays =
      build_conn()
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> get("/logout")

    assert stays.status == 405
    assert get_session(stays, :user_id) == user.id
  end

  test "suspended user is logged out of dead views and LiveViews", %{
    conn: conn,
    owner: owner,
    bucket: bucket
  } do
    authed = login(conn, owner)

    {:ok, _view, html} = live(authed, "/app/b/#{bucket}")
    assert html =~ "doc.txt"

    {:ok, _} = Accounts.update_user(owner, %{is_active: false})

    assert {:error, {:redirect, %{to: "/login"}}} =
             build_conn()
             |> Plug.Test.init_test_session(%{user_id: owner.id})
             |> live("/app/keys")

    kicked =
      build_conn()
      |> Plug.Test.init_test_session(%{user_id: owner.id})
      |> get("/files/#{bucket}/doc.txt")

    assert redirected_to(kicked) == "/login"
  end

  test "password login redirects to the app", %{conn: conn} do
    user = create_user("lv-login")

    conn = post(conn, "/login", %{"username" => user.username, "password" => "secret1234"})
    assert redirected_to(conn) == "/app"
    assert get_session(conn, :user_id) == user.id
  end

  test "password login rejects wrong credentials", %{conn: conn} do
    user = create_user("lv-login-fail")

    conn = post(conn, "/login", %{"username" => user.username, "password" => "wrong"})
    assert conn.status == 200
    assert conn.resp_body =~ "Sign in failed"
    assert get_session(conn, :user_id) == nil
  end
end
