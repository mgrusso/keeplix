defmodule KeeplixWeb.SessionController do
  use KeeplixWeb, :controller

  alias Keeplix.Audit

  @spec login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def login(conn, _params) do
    render(conn, :login, oidc_enabled: Keeplix.Oidc.enabled?())
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"username" => username, "password" => password})
      when is_binary(username) and is_binary(password) do
    alias Keeplix.RateLimit

    ip = RateLimit.client_ip(conn)
    user_key = rate_key(username)

    if RateLimit.check(:login_ip, ip) == :blocked or
         RateLimit.check(:login_user, user_key) == :blocked do
      Audit.log(nil, "auth.throttled", username, %{ip: ip})

      conn
      |> put_status(429)
      |> put_flash(:error, "Too many failed attempts. Try again later.")
      |> render(:login, oidc_enabled: Keeplix.Oidc.enabled?())
    else
      case Keeplix.Accounts.authenticate(username, password) do
        {:ok, user} ->
          now = System.system_time(:second)

          if Keeplix.WebAuthn.second_factor_required?(user) do
            Audit.log(user, "auth.password", user.username, %{ip: ip})

            conn
            |> configure_session(renew: true)
            |> put_session(:pending_2fa_user_id, user.id)
            |> put_flash(:info, "Password accepted. Confirm with your second factor.")
            |> redirect(to: "/login/2fa")
          else
            Audit.log(user, "auth.login", user.username, %{ip: ip})

            conn
            |> configure_session(renew: true)
            |> put_session(:user_id, user.id)
            |> put_session(:session_issued_at, now)
            |> put_session(:session_last_seen_at, now)
            |> put_flash(:info, "Welcome, #{user.username}!")
            |> redirect(to: "/app")
          end

        {:error, _} ->
          RateLimit.track_failure(:login_ip, ip)
          RateLimit.track_failure(:login_user, user_key)
          Audit.log(nil, "auth.failed_login", username, %{ip: ip})

          conn
          |> put_flash(:error, "Sign in failed.")
          |> render(:login, oidc_enabled: Keeplix.Oidc.enabled?())
      end
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Sign in failed.")
    |> render(:login, oidc_enabled: Keeplix.Oidc.enabled?())
  end

  defp rate_key(username) do
    username |> String.trim() |> String.downcase()
  rescue
    _ -> "invalid"
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn |> clear_session() |> redirect(to: "/login")
  end

  @doc """
  Completes a second-factor login: consumes the one-time token issued by
  the ceremony LiveView. Requires the matching pending login in the
  session, so a token alone never suffices.
  """
  @spec finish_2fa(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def finish_2fa(conn, %{"token" => token}) do
    alias Keeplix.Accounts
    pending = get_session(conn, :pending_2fa_user_id)

    with {:ok, user_id} <- Keeplix.LoginTokens.consume(token),
         true <- is_integer(pending) and pending == user_id,
         %Accounts.User{is_active: true} = user <- Accounts.get_user(user_id) do
      now = System.system_time(:second)

      Audit.log(user, "auth.login", user.username, %{
        ip: Keeplix.RateLimit.client_ip(conn),
        via: "2fa"
      })

      conn
      |> configure_session(renew: true)
      |> put_session(:user_id, user.id)
      |> put_session(:session_issued_at, now)
      |> put_session(:session_last_seen_at, now)
      |> delete_session(:pending_2fa_user_id)
      |> put_flash(:info, "Welcome, #{user.username}!")
      |> redirect(to: "/app")
    else
      _ ->
        conn
        |> put_flash(:error, "Verification expired. Sign in again.")
        |> redirect(to: "/login")
    end
  end

  def finish_2fa(conn, _params) do
    conn |> put_flash(:error, "Verification expired. Sign in again.") |> redirect(to: "/login")
  end

  @spec logout_get(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def logout_get(conn, _params) do
    conn |> put_status(405) |> text("Method not allowed. Sign out uses DELETE /logout.")
  end
end
