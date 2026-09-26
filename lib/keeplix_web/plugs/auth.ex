defmodule KeeplixWeb.Plugs.Auth do
  import Plug.Conn
  import Phoenix.Controller

  def init(action), do: action

  def call(conn, :fetch_current_user), do: fetch_current_user(conn, [])
  def call(conn, :require_login), do: require_login(conn, [])
  def call(conn, :require_admin), do: require_admin(conn, [])

  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, :user_id)

    user =
      if user_id do
        Keeplix.Accounts.get_user(user_id)
      end

    # Suspended users are treated as logged out everywhere.
    assign(conn, :current_user, if(user && user.is_active, do: user))
  end

  def require_login(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> clear_session()
      |> put_flash(:error, "Please sign in first.")
      |> redirect(to: "/login")
      |> halt()
    end
  end

  def require_admin(conn, _opts) do
    case conn.assigns[:current_user] do
      %{role: "admin"} ->
        conn

      %{role: _} ->
        conn
        |> put_flash(:error, "Admins only.")
        |> redirect(to: "/app")
        |> halt()

      _ ->
        conn
        |> clear_session()
        |> put_flash(:error, "Please sign in first.")
        |> redirect(to: "/login")
        |> halt()
    end
  end

  # LiveView guard: re-checked on every mount (incl. reconnects), unlike
  # controller plugs which only run on the initial HTTP request.
  def on_mount(:ensure_active, _params, session, socket) do
    if active_session_user?(session) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  def on_mount(:ensure_admin, _params, session, socket) do
    case active_session_user?(session) do
      %{role: "admin"} -> {:cont, socket}
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  defp active_session_user?(session) do
    user_id = session["user_id"] || session[:user_id]
    user = user_id && Keeplix.Accounts.get_user(user_id)
    if user && user.is_active, do: user
  end
end
