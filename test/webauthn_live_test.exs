defmodule KeeplixWeb.WebAuthnLiveTest do
  @moduledoc """
  Second-factor login flows without a browser: password step, backup
  codes end-to-end (incl. session establishment), token finish endpoint,
  and passkey management events (Phase A).
  """
  use KeeplixWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Keeplix.{Accounts, LoginTokens, Repo, WebAuthn}
  alias Keeplix.WebAuthn.Credential

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "wa2fa-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    {:ok, conn: conn, user: user}
  end

  defp with_credential(user) do
    %Credential{user_id: user.id}
    |> Credential.changeset(%{
      label: "test",
      credential_id: "cred-#{System.unique_integer([:positive])}",
      public_key: Base.encode64(:erlang.term_to_binary(%{1 => 2}))
    })
    |> Repo.insert!()
  end

  defp login_session(conn, user, extra \\ %{}) do
    Plug.Test.init_test_session(conn, Map.merge(%{user_id: user.id}, extra))
  end

  # ---------- password step ----------

  test "password login with 2FA user lands on the second step", %{conn: conn, user: user} do
    with_credential(user)

    conn = post(conn, "/login", %{"username" => user.username, "password" => "secret1234"})
    assert redirected_to(conn) == "/login/2fa"
    assert get_session(conn, :user_id) == nil
    assert get_session(conn, :pending_2fa_user_id) == user.id
  end

  test "second step without pending login redirects away", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, "/login/2fa")
  end

  # ---------- backup-code end-to-end ----------

  test "backup code completes login incl. session", %{conn: conn, user: user} do
    with_credential(user)
    {:ok, [code | _]} = WebAuthn.generate_backup_codes(user)

    authed = login_session(conn, user, %{user_id: nil, pending_2fa_user_id: user.id})
    {:ok, view, _} = live(authed, "/login/2fa")

    render_submit(view, "use-backup-code", %{"code" => code})
    {to, _flash} = assert_redirect(view)
    assert to =~ "/login/2fa/finish?token="
    %URI{query: query} = URI.parse(to)
    %{"token" => token} = URI.decode_query(query)

    done =
      build_conn()
      |> Plug.Test.init_test_session(%{pending_2fa_user_id: user.id})
      |> get("/login/2fa/finish?token=#{token}")

    assert redirected_to(done) == "/app"
    assert get_session(done, :user_id) == user.id
  end

  test "wrong backup code fails", %{conn: conn, user: user} do
    with_credential(user)
    {:ok, _} = WebAuthn.generate_backup_codes(user)

    authed = login_session(conn, user, %{user_id: nil, pending_2fa_user_id: user.id})
    {:ok, view, _} = live(authed, "/login/2fa")

    html = render_submit(view, "use-backup-code", %{"code" => "nope-nope"})
    assert html =~ "Invalid backup code"
  end

  # ---------- finish endpoint ----------

  test "finish rejects bad tokens and mismatched sessions", %{user: user} do
    bad =
      build_conn()
      |> Plug.Test.init_test_session(%{pending_2fa_user_id: user.id})
      |> get("/login/2fa/finish?token=bogus")

    assert redirected_to(bad) == "/login"
    assert get_session(bad, :user_id) == nil

    {:ok, other} =
      Accounts.create_user(%{
        username: "wa2fa-o-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    token = LoginTokens.issue(user.id)

    mismatched =
      build_conn()
      |> Plug.Test.init_test_session(%{pending_2fa_user_id: other.id})
      |> get("/login/2fa/finish?token=#{token}")

    assert redirected_to(mismatched) == "/login"
    assert get_session(mismatched, :user_id) == nil
  end

  test "finish rejects suspended users", %{user: user} do
    token = LoginTokens.issue(user.id)
    {:ok, _} = Accounts.update_user(user, %{is_active: false})

    done =
      build_conn()
      |> Plug.Test.init_test_session(%{pending_2fa_user_id: user.id})
      |> get("/login/2fa/finish?token=#{token}")

    assert redirected_to(done) == "/login"
    assert get_session(done, :user_id) == nil
  end

  test "login tokens are single-use and expire" do
    {:ok, uid} = {:ok, 123}
    token = LoginTokens.issue(uid)
    assert {:ok, ^uid} = LoginTokens.consume(token)
    assert {:error, :invalid} = LoginTokens.consume(token)

    expired = LoginTokens.issue(uid, -5)
    assert {:error, :expired} = LoginTokens.consume(expired)
    assert {:error, :invalid} = LoginTokens.consume(nil)
  end

  # ---------- passkey management events ----------

  test "begin pushes an authentication challenge", %{conn: conn, user: user} do
    with_credential(user)

    authed = login_session(conn, user, %{user_id: nil, pending_2fa_user_id: user.id})
    {:ok, view, _} = live(authed, "/login/2fa")

    render_click(view, "begin")

    assert_push_event(view, "webauthn-authenticate", %{
      challenge: _,
      rpId: _,
      allowCredentials: [_ | _]
    })
  end

  test "garbage attestation fails cleanly", %{conn: conn, user: user} do
    with_credential(user)

    authed = login_session(conn, user, %{user_id: nil, pending_2fa_user_id: user.id})
    {:ok, view, _} = live(authed, "/login/2fa")
    render_click(view, "begin")

    html =
      render_click(view, "verify", %{
        "id" => "x",
        "authData" => "eA",
        "signature" => "eA",
        "clientData" => "{}"
      })

    assert html =~ "verification failed"
  end

  test "profile backup codes and credential management", %{conn: conn, user: user} do
    cred = with_credential(user)

    authed = login_session(conn, user)
    {:ok, view, _} = live(authed, "/app/profile")

    html = render_click(view, "generate-codes")
    assert html =~ "shown only once"
    assert WebAuthn.remaining_backup_codes(user) == 10

    render_click(view, "webauthn-begin", %{"label" => "new key"})
    assert_push_event(view, "webauthn-register", %{challenge: _, rpId: _, userName: _})

    html =
      render_submit(view, "rename-credential", %{"credential_id" => cred.id, "label" => "renamed"})

    assert html =~ "renamed"

    html = render_click(view, "delete-credential", %{"credential_id" => cred.id})
    assert html =~ "removed"
    assert WebAuthn.list_credentials(user) == []
  end

  test "admin can reset two-factor methods", %{conn: conn} do
    {:ok, admin} =
      Accounts.create_user(%{
        username: "wa2fa-a-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "admin"
      })

    {:ok, victim} =
      Accounts.create_user(%{
        username: "wa2fa-v-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    with_credential(victim)
    {:ok, _} = WebAuthn.generate_backup_codes(victim)

    authed = login_session(conn, admin)
    {:ok, view, _} = live(authed, "/admin/users")
    render_click(view, "select", %{"id" => victim.id})

    html = render_click(view, "reset-2fa", %{})
    assert html =~ "Two-factor methods removed"
    assert WebAuthn.list_credentials(victim) == []
    assert WebAuthn.remaining_backup_codes(victim) == 0
  end
end
