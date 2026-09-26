defmodule KeeplixWeb.ApiManagementTest do
  @moduledoc """
  Management API v1 (item 2): admin-only JSON CRUD behind HTTP Basic.
  """
  use KeeplixWeb.ConnCase

  alias Keeplix.{Accounts, Buckets}

  setup %{conn: conn} do
    {:ok, admin} =
      Accounts.create_user(%{username: "api-admin", password: "secret1234", role: "admin"})

    {:ok, plain} =
      Accounts.create_user(%{username: "api-user", password: "secret1234", role: "user"})

    {:ok, conn: conn, admin: admin, plain: plain}
  end

  defp as(conn, username, password \\ "secret1234") do
    Plug.Conn.put_req_header(
      conn,
      "authorization",
      "Basic " <> Base.encode64("#{username}:#{password}")
    )
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  test "rejects anonymous, wrong and non-admin credentials", %{conn: conn} do
    assert get(conn, "/api/v1/users").status == 401

    assert conn |> as("api-admin", "wrong") |> get("/api/v1/users") |> Map.fetch!(:status) == 401

    assert conn |> as("api-user") |> get("/api/v1/users") |> Map.fetch!(:status) == 401
  end

  test "failed attempts are audit-logged", %{conn: conn} do
    conn |> as("api-admin", "wrong") |> get("/api/v1/users")
    assert Keeplix.Audit.list_recent(50) |> Enum.any?(&(&1.action == "api.auth_failed"))
  end

  test "brute force is throttled with 429", %{conn: conn} do
    Keeplix.RateLimit.reset_all()
    old_env = Application.get_env(:keeplix, Keeplix.RateLimit)

    Application.put_env(:keeplix, Keeplix.RateLimit,
      api_ip: [max_attempts: 2, window_ms: 60_000, block_ms: 60_000]
    )

    on_exit(fn ->
      if old_env,
        do: Application.put_env(:keeplix, Keeplix.RateLimit, old_env),
        else: Application.delete_env(:keeplix, Keeplix.RateLimit)

      Keeplix.RateLimit.reset_all()
    end)

    assert conn |> as("api-admin", "wrong") |> get("/api/v1/users") |> Map.fetch!(:status) == 401
    assert conn |> as("api-admin", "wrong") |> get("/api/v1/users") |> Map.fetch!(:status) == 401

    blocked = conn |> as("api-admin", "wrong") |> get("/api/v1/users")
    assert blocked.status == 429
    assert Jason.decode!(blocked.resp_body)["error"]["code"] == "too_many_requests"
  end

  test "users CRUD", %{conn: conn} do
    created =
      conn |> as("api-admin") |> post("/api/v1/users", %{username: "bob", password: "secret1234"})

    assert created.status == 201
    %{"user" => %{"id" => id, "username" => "bob"}} = json_body(created)

    listed = conn |> as("api-admin") |> get("/api/v1/users")
    assert listed.status == 200
    assert %{"users" => users} = json_body(listed)
    assert Enum.any?(users, &(&1["username"] == "bob"))

    updated =
      conn |> as("api-admin") |> patch("/api/v1/users/#{id}", %{is_active: false})

    assert updated.status == 200
    assert %{"user" => %{"is_active" => false}} = json_body(updated)

    assert conn |> as("api-admin") |> delete("/api/v1/users/#{id}") |> Map.fetch!(:status) == 204
    assert conn |> as("api-admin") |> get("/api/v1/users/#{id}") |> Map.fetch!(:status) == 404
  end

  test "user validation errors are 422", %{conn: conn} do
    conn = conn |> as("api-admin") |> post("/api/v1/users", %{username: "x"})
    assert conn.status == 422
    assert %{"error" => %{"code" => "invalid"}} = json_body(conn)
  end

  test "self and last-admin protection", %{conn: conn, admin: admin} do
    # Cannot delete self.
    assert conn |> as("api-admin") |> delete("/api/v1/users/#{admin.id}") |> Map.fetch!(:status) ==
             403

    # Cannot delete or demote the last admin (self is the only one).
    assert conn
           |> as("api-admin")
           |> patch("/api/v1/users/#{admin.id}", %{role: "user"})
           |> Map.fetch!(:status) == 403

    assert conn
           |> as("api-admin")
           |> patch("/api/v1/users/#{admin.id}", %{is_active: false})
           |> Map.fetch!(:status) == 403

    # A second admin removes the last-admin block (but not self-delete).
    created =
      conn
      |> as("api-admin")
      |> post("/api/v1/users", %{username: "admin2", password: "secret1234", role: "admin"})

    %{"user" => %{"id" => admin2_id}} = json_body(created)

    assert conn
           |> as("api-admin")
           |> patch("/api/v1/users/#{admin2_id}", %{role: "user"})
           |> Map.fetch!(:status) == 200

    assert conn |> as("api-admin") |> delete("/api/v1/users/#{admin2_id}") |> Map.fetch!(:status) ==
             204

    # Still cannot delete self.
    assert conn |> as("api-admin") |> delete("/api/v1/users/#{admin.id}") |> Map.fetch!(:status) ==
             403

    assert Accounts.get_user(admin.id) != nil
  end

  test "groups CRUD with members", %{conn: conn, plain: plain} do
    created = conn |> as("api-admin") |> post("/api/v1/groups", %{name: "devs"})
    assert created.status == 201
    %{"group" => %{"id" => gid}} = json_body(created)

    added =
      conn |> as("api-admin") |> post("/api/v1/groups/#{gid}/members", %{user_id: plain.id})

    assert added.status == 200
    assert %{"group" => %{"member_ids" => [member]}} = json_body(added)
    assert member == plain.id

    assert conn
           |> as("api-admin")
           |> delete("/api/v1/groups/#{gid}/members/#{plain.id}")
           |> Map.fetch!(:status) == 204

    assert conn |> as("api-admin") |> delete("/api/v1/groups/#{gid}") |> Map.fetch!(:status) ==
             204
  end

  test "buckets CRUD", %{conn: conn} do
    created = conn |> as("api-admin") |> post("/api/v1/buckets", %{name: "api-bucket-1"})
    assert created.status == 201
    assert %{"bucket" => %{"owner" => "api-admin"}} = json_body(created)

    shown = conn |> as("api-admin") |> get("/api/v1/buckets/api-bucket-1")
    assert shown.status == 200

    updated =
      conn |> as("api-admin") |> patch("/api/v1/buckets/api-bucket-1", %{quota_bytes: 123_456})

    assert updated.status == 200
    assert %{"bucket" => %{"quota_bytes" => 123_456}} = json_body(updated)

    assert conn
           |> as("api-admin")
           |> delete("/api/v1/buckets/api-bucket-1")
           |> Map.fetch!(:status) == 204

    assert Buckets.get_bucket("api-bucket-1") == nil
  end

  test "access keys: secret only at creation", %{conn: conn, plain: plain} do
    created =
      conn |> as("api-admin") |> post("/api/v1/users/#{plain.id}/keys", %{description: "ci"})

    assert created.status == 201
    assert %{"key" => %{"access_key_id" => akid, "secret" => secret}} = json_body(created)
    assert is_binary(secret) and secret != ""

    listed = conn |> as("api-admin") |> get("/api/v1/users/#{plain.id}/keys")
    assert %{"keys" => [%{"access_key_id" => ^akid}]} = json_body(listed)
    refute json_body(listed)["keys"] |> hd() |> Map.has_key?("secret")

    key = Accounts.get_key_by_access_id(akid)

    assert conn
           |> as("api-admin")
           |> delete("/api/v1/users/#{plain.id}/keys/#{key.id}")
           |> Map.fetch!(:status) == 204
  end

  test "mutating calls are audit-logged", %{conn: conn} do
    conn |> as("api-admin") |> post("/api/v1/groups", %{name: "audited"})
    assert Keeplix.Audit.list_recent(50) |> Enum.any?(&(&1.action == "api.group.create"))
  end

  test "bearer tokens authenticate", %{conn: conn, admin: admin} do
    {:ok, _, plain} = Accounts.create_api_token(admin, "ci")

    authed =
      Plug.Conn.put_req_header(conn, "authorization", "Bearer #{plain}")

    listed = get(authed, "/api/v1/users")
    assert listed.status == 200
    assert Jason.decode!(listed.resp_body)["users"] != []
  end

  test "unknown bearer is 401", %{conn: conn} do
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer kp_bogus")
    assert get(conn, "/api/v1/users").status == 401
  end

  test "basic auth blocked with 2FA enrolled, bearer still works", %{conn: conn, admin: admin} do
    %Keeplix.WebAuthn.Credential{}
    |> Keeplix.WebAuthn.Credential.changeset(%{credential_id: "cred-1", public_key: "pk"})
    |> Ecto.Changeset.put_change(:user_id, admin.id)
    |> Keeplix.Repo.insert!()

    basic = conn |> as("api-admin") |> get("/api/v1/users")
    assert basic.status == 403
    assert Jason.decode!(basic.resp_body)["error"]["code"] == "2fa_required"

    {:ok, _, plain} = Accounts.create_api_token(admin, "ci-2fa")

    authed = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{plain}")
    assert get(authed, "/api/v1/users").status == 200
  end

  test "user tokens CRUD via API", %{conn: conn, plain: plain} do
    created =
      conn |> as("api-admin") |> post("/api/v1/users/#{plain.id}/tokens", %{name: "t1"})

    assert created.status == 201
    %{"token" => %{"token" => secret, "id" => id}} = Jason.decode!(created.resp_body)
    assert String.starts_with?(secret, "kp_")

    listed = conn |> as("api-admin") |> get("/api/v1/users/#{plain.id}/tokens")
    assert %{"tokens" => [%{"id" => ^id, "name" => "t1"}]} = Jason.decode!(listed.resp_body)

    assert conn
           |> as("api-admin")
           |> delete("/api/v1/users/#{plain.id}/tokens/#{id}")
           |> Map.fetch!(:status) == 204
  end
end
