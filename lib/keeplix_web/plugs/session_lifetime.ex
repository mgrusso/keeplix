defmodule KeeplixWeb.Plugs.SessionLifetime do
  @moduledoc """
  Absolute (12h) and idle (30m) session lifetimes.

  Runs in the authenticated pipelines and as a LiveView `on_mount` hook,
  so both dead views and LiveViews expire. Limits are overridable:

      config :keeplix, KeeplixWeb.Plugs.SessionLifetime,
        absolute_seconds: 12 * 3600,
        idle_seconds: 30 * 60
  """
  import Plug.Conn
  import Phoenix.Controller

  @defaults [absolute_seconds: 12 * 3_600, idle_seconds: 30 * 60]

  def init(_opts), do: []

  def call(conn, _) do
    now = System.system_time(:second)
    issued = get_session(conn, :session_issued_at)
    seen = get_session(conn, :session_last_seen_at)

    case expired?(issued, seen, now) do
      :expired ->
        conn
        |> clear_session()
        |> put_flash(:error, "Session expired. Please sign in again.")
        |> redirect(to: "/login")
        |> halt()

      :refresh ->
        # Sessions from before this feature: adopt them transparently.
        conn
        |> put_session(:session_issued_at, now)
        |> put_session(:session_last_seen_at, now)

      :ok ->
        put_session(conn, :session_last_seen_at, now)
    end
  end

  def on_mount(:ensure_fresh, _params, session, socket) do
    now = System.system_time(:second)
    issued = session["session_issued_at"] || session[:session_issued_at]
    seen = session["session_last_seen_at"] || session[:session_last_seen_at]

    case expired?(issued, seen, now) do
      :expired -> {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
      _ -> {:cont, socket}
    end
  end

  @doc """
  Pure lifetime decision (injectable clock for tests):
  `:ok`, `:refresh` (pre-feature sessions), or `:expired`.
  """
  @spec expired?(term(), term(), integer()) :: :ok | :refresh | :expired
  def expired?(issued, seen, now \\ System.system_time(:second)) do
    cond do
      not is_integer(issued) or not is_integer(seen) -> :refresh
      now - issued > absolute_seconds() or now - seen > idle_seconds() -> :expired
      true -> :ok
    end
  end

  defp absolute_seconds,
    do: Keyword.get(config(), :absolute_seconds, @defaults[:absolute_seconds])

  defp idle_seconds, do: Keyword.get(config(), :idle_seconds, @defaults[:idle_seconds])

  defp config, do: Application.get_env(:keeplix, __MODULE__, []) || []
end
