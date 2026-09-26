defmodule KeeplixWeb.Plugs.Locale do
  @moduledoc """
  UI locale (en/de): explicit session choice wins, then the user's saved
  preference, then the browser's Accept-Language header, else English.

  Runs both as a browser plug and as a LiveView on_mount hook (LiveView
  socket processes don't inherit the plug's process locale).
  """
  import Plug.Conn

  @locales ["en", "de"]

  def init(opts), do: opts

  def call(conn, _opts) do
    locale =
      resolve(
        get_session(conn, :locale),
        current_user(conn),
        get_req_header(conn, "accept-language")
      )

    Gettext.put_locale(KeeplixWeb.Gettext, locale)

    conn
    |> put_session(:locale, locale)
    |> assign(:locale, locale)
  end

  def on_mount(:default, _params, session, socket) do
    locale =
      resolve(session["locale"], socket.assigns[:current_user], [])

    Gettext.put_locale(KeeplixWeb.Gettext, locale)

    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  @doc """
  Switches the session (and, when logged in, the stored user preference).
  """
  @spec switch(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def switch(conn, locale) when locale in @locales do
    Gettext.put_locale(KeeplixWeb.Gettext, locale)

    if user = current_user(conn) do
      Keeplix.Accounts.update_user(user, %{"locale" => locale})
    end

    conn |> put_session(:locale, locale) |> assign(:locale, locale)
  end

  def switch(conn, _), do: conn

  defp current_user(conn) do
    case conn.assigns[:current_user] do
      %{is_active: true} = user -> user
      _ -> nil
    end
  end

  defp resolve(locale, _user, _headers) when locale in @locales, do: locale

  defp resolve(_locale, %{locale: user_locale}, _headers) when user_locale in @locales,
    do: user_locale

  defp resolve(_locale, _user, [header | _]) do
    header
    |> String.split(",")
    |> Enum.map(
      &(&1
        |> String.split(";")
        |> hd()
        |> String.trim()
        |> String.slice(0, 2)
        |> String.downcase())
    )
    |> Enum.find("en", &(&1 in @locales))
  end

  defp resolve(_, _, _), do: "en"
end
