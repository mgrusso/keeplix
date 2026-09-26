defmodule KeeplixWeb.OidcController do
  use KeeplixWeb, :controller

  require Logger

  @spec request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request(conn, _params) do
    case Keeplix.Oidc.authorize_url() do
      {:ok, url, session_params} ->
        conn
        |> put_session(:oidc_session_params, session_params)
        |> redirect(external: url)

      {:error, _} ->
        conn |> put_flash(:error, "SSO is not configured.") |> redirect(to: "/login")
    end
  end

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, params) do
    session_params = get_session(conn, :oidc_session_params, %{})

    case Keeplix.Oidc.callback(params, session_params) do
      {:ok, user} ->
        now = System.system_time(:second)

        conn
        |> delete_session(:oidc_session_params)
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> put_session(:session_issued_at, now)
        |> put_session(:session_last_seen_at, now)
        |> put_flash(:info, "Signed in via SSO.")
        |> redirect(to: "/app")

      {:error, :inactive} ->
        conn
        |> put_flash(:error, "Account is disabled. Contact an administrator.")
        |> redirect(to: "/login")

      {:error, :username_taken} ->
        conn
        |> put_flash(
          :error,
          "An account with this username already exists and is not linked to single sign-on. Ask an administrator to link it."
        )
        |> redirect(to: "/login")

      {:error, reason} ->
        # Never reflect IdP internals to the browser; log them instead.
        Logger.error("OIDC callback failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Single sign-on failed. Try again or contact an administrator.")
        |> redirect(to: "/login")
    end
  end
end
