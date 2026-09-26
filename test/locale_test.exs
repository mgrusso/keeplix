defmodule KeeplixWeb.LocaleTest do
  @moduledoc """
  UI locales (item 5): accept-language fallback, profile switch, persistence.
  """
  use KeeplixWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Keeplix.Accounts

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "loc-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, user: user}
  end

  test "login page follows Accept-Language" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept-language", "de-DE,de;q=0.9")
      |> get("/login")

    assert conn.status == 200
    assert conn.resp_body =~ "Anmelden"
    refute conn.resp_body =~ ">Sign in<"
  end

  test "login page defaults to English" do
    conn = Phoenix.ConnTest.build_conn() |> get("/login")
    assert conn.resp_body =~ ">Sign in<"
  end

  test "profile switch persists and translates the UI", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, "/app/profile")

    html = render_submit(view, "save-locale", %{"locale" => "de"})
    assert html =~ "Sprache aktualisiert"

    assert Accounts.get_user(user.id).locale == "de"

    {:ok, _view2, keys_html} = live(conn, "/app/keys")
    assert keys_html =~ "Zugangsschlüssel"
    assert keys_html =~ "Kopieren" or keys_html =~ "Erstellen"
  end

  test "invalid locale is ignored", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, "/app/profile")
    render_submit(view, "save-locale", %{"locale" => "xx"})
    assert Accounts.get_user(user.id).locale == "en"
  end

  test "saved preference applies on next visit", %{conn: conn, user: user} do
    {:ok, _} = Accounts.update_user(user, %{"locale" => "de"})
    {:ok, _view, html} = live(conn, "/app/help")
    assert html =~ "Tastaturkürzel"
  end
end
