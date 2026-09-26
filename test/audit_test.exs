defmodule KeeplixWeb.AuditTest do
  @moduledoc """
  Audit trail for admin and self-service actions (P3).
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing
  import Phoenix.LiveViewTest

  alias Keeplix.{Accounts, Audit, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, admin} =
      Accounts.create_user(%{
        username: "audit-admin-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "admin"
      })

    {:ok, conn: conn, admin: admin}
  end

  defp actions, do: Audit.list_recent(100) |> Enum.map(&{&1.action, &1.target, &1.actor_username})

  test "admin user deletion is audited", %{conn: conn, admin: admin} do
    {:ok, victim} =
      Accounts.create_user(%{
        username: "audit-victim-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    {:ok, view, _} =
      conn |> Plug.Test.init_test_session(%{user_id: admin.id}) |> live("/admin/users")

    render_click(view, "delete", %{"id" => victim.id})

    assert {"user.delete", victim.username, admin.username} in actions()
  end

  test "self-service key creation is audited", %{conn: conn} do
    {:ok, bob} =
      Accounts.create_user(%{
        username: "audit-bob-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    {:ok, view, _} =
      conn |> Plug.Test.init_test_session(%{user_id: bob.id}) |> live("/app/keys")

    render_submit(view, "create", %{"description" => "audited"})

    assert Enum.any?(actions(), fn {action, _target, actor} ->
             action == "key.create" and actor == bob.username
           end)
  end

  test "failed and successful logins are audited", %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "audit-login-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    post(conn, "/login", %{"username" => user.username, "password" => "wrong"})
    assert {"auth.failed_login", user.username, nil} in actions()

    post(conn, "/login", %{"username" => user.username, "password" => "secret1234"})
    assert {"auth.login", user.username, user.username} in actions()
  end

  test "S3 throttling is audited", %{conn: conn} do
    old = Application.get_env(:keeplix, Keeplix.RateLimit, [])

    Application.put_env(:keeplix, Keeplix.RateLimit,
      s3_ip: [max_attempts: 1, window_ms: 60_000, block_ms: 60_000]
    )

    Keeplix.RateLimit.reset_all()

    on_exit(fn ->
      Application.put_env(:keeplix, Keeplix.RateLimit, old)
      Keeplix.RateLimit.reset_all()
    end)

    conn =
      signed_request(conn, "GET", "/nope",
        query: "list-type=2",
        creds: %{access_key_id: "NOPE", secret: "nope"}
      )

    assert conn.status in [403, 429]

    conn =
      signed_request(conn, "GET", "/nope",
        query: "list-type=2",
        creds: %{access_key_id: "NOPE", secret: "nope"}
      )

    assert conn.status == 429
    assert Enum.any?(actions(), fn {action, _, _} -> action == "s3.throttled" end)
  end

  test "audit page lists recent events", %{conn: conn, admin: admin} do
    Audit.log(admin, "test.action", "test-target", %{})

    {:ok, _view, html} =
      conn |> Plug.Test.init_test_session(%{user_id: admin.id}) |> live("/admin/audit")

    assert html =~ "test.action"
    assert html =~ "test-target"
  end

  test "key last use is shown after S3 activity", %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "audit-used-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "audit-used-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, user)
    {:ok, _, creds} = Accounts.create_access_key(user, "used")
    on_exit(fn -> Storage.delete_bucket(bucket) end)

    authed = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, _view, html} = live(authed, "/app/keys")
    assert html =~ "Last used: never"

    signed_request(build_conn(), "GET", "/#{bucket}", query: "list-type=2", creds: creds)

    {:ok, _view2, html2} =
      build_conn() |> Plug.Test.init_test_session(%{user_id: user.id}) |> live("/app/keys")

    assert html2 =~ "Last used:"
    refute html2 =~ "Last used: never"
  end
end
